
module protocol.mongrel2;

import std.ascii;
public import protocol.http;
import std.stdio, std.string, std.conv, std.stdint, std.array, std.range,
       std.datetime, std.algorithm, std.concurrency, std.typecons, std.random, std.utf;

import std.json;
import zmq;

string zmqIdentity;
bool running = true;

// ------------------------------------------------------------------------- //

class ZMQMsg
{
    zmq_msg_t * msg;
    char[] msg_data;

    this()
    {
        msg = cast(zmq_msg_t *) std.c.stdlib.malloc( zmq_msg_t.sizeof );
        zmq_msg_init( msg );
    }

    this( char[] buf )
    {
        msg = cast(zmq_msg_t *) std.c.stdlib.malloc( zmq_msg_t.sizeof );
        zmq_msg_init_size( msg, buf.length );
        std.c.string.memcpy( zmq_msg_data( msg ), buf.ptr, buf.length );
    }

    ~this()
    {
        destroy();
    }

    @property ulong length()
    {
        return (msg is null) ? 0UL : zmq_msg_size( msg );
    }

    @property char[] data()
    {
        if( msg_data.length == 0 && msg !is null )
        {
            msg_data.length = zmq_msg_size( msg );
            if( msg_data.length > 0 )
                std.c.string.memcpy( msg_data.ptr, zmq_msg_data( msg ), msg_data.length );

            destroy();
        }
        return msg_data;
    }

    zmq_msg_t * opCast( T: zmq_msg_t * )()
    {
        return msg;
    }

    void destroy()
    {
        if( msg !is null )
            std.c.stdlib.free( msg );

        msg = null;
    }
}

// ------------------------------------------------------------------------- //

class ZMQConnection
{
    static void * zmqCtx;
    static string zmqIdent;

    static this()
    {
        zmqCtx = zmq_init( 1 );
    }

    void * zmqSock;
    ZMQMsg zmqMsg;

    this( string addr, int type )
    {
        zmqSock = zmq_socket( zmqCtx, type );
        zmq_connect( zmqSock, addr.toStringz );
    }

    ~this()
    {
    }

    ZMQMsg receive( int flags = 0 )
    {
        if( zmqMsg is null )
            zmqMsg = new ZMQMsg();

        if( zmq_recv( zmqSock, cast( zmq_msg_t* ) zmqMsg, flags ) == 0 )
        {
            ZMQMsg msg = zmqMsg;
            zmqMsg = null;
            return msg;
        }
        return null;
    }

    void send( ZMQMsg msg )
    {
        zmq_send( zmqSock, cast( zmq_msg_t * ) msg, 0 ); //send it off
        msg.destroy();
    }

    void * opCast( T : void * )()
    {
        return zmqSock;
    }
}

// ------------------------------------------------------------------------- //

void mongrel2ServeImpl( ZMQConnection zmqReceive, HttpProcessor proc )
{
    int major, minor, patch;
    zmq_version( &major, &minor, &patch );
    proc.onLog( format( "zmq_version = %d.%d.%d", major, minor, patch ) );

    char[ 20 ] ident;
    for( auto i = 0; i < 20; ++i )
        ident[ i ] = uniform( 'a', 'z' );

    zmqIdentity = ident.idup;
    writeln( "Identity: ", ident );
//    zmq_setsockopt( zmqReceive, ZMQ_IDENTITY, cast(char *) zmqIdentity.toStringz, zmqIdentity.length );


    bool done = false;
    while( !done )
    {
        ZMQMsg msg = zmqReceive.receive();
        if( msg !is null )
        {
            debug dumpHex( msg.data );

            HttpRequest req = parseMongrelRequest( msg.data );
            if( req !is null && !isDisconnect( req ) )
                proc.onRequest( req );
        }

        proc.onIdle();
    }
    proc.onExit();
}

// ------------------------------------------------------------------------- //

void mongrel2Serve( string addrPull, string addrPub, RequestDelegate dg )
{
    auto resPull = parseAddr( addrPull, SERVER_PORT );
    auto resPub  = parseAddr( addrPub, SERVER_PORT );

    string pull = format( "tcp://%s:%d", resPull[ 0 ], resPull[ 1 ] );
    string pub  = format( "tcp://%s:%d", resPub[ 0 ], resPub[ 1 ] );

    ZMQConnection zmqReceive = new ZMQConnection( pull, ZMQ_PULL );
    ZMQConnection zmqPublish = new ZMQConnection( pub, ZMQ_PUB );

    HttpProcessor proc = new DelegateProcessor( dg, zmqPublish );
    proc.onLog( "Executing in SYNC mode" );

    mongrel2ServeImpl( zmqReceive, proc );
}

// ------------------------------------------------------------------------- //

void mongrel2Serve( string addrPull, string addrPub, Tid tid )
{
    auto resPull = parseAddr( addrPull, SERVER_PORT );
    auto resPub  = parseAddr( addrPub, SERVER_PORT );

    string pull = format( "tcp://%s:%d", resPull[ 0 ], resPull[ 1 ] );
    string pub  = format( "tcp://%s:%d", resPub[ 0 ], resPub[ 1 ] );

    ZMQConnection zmqReceive = new ZMQConnection( pull, ZMQ_PULL );
    ZMQConnection zmqPublish = new ZMQConnection( pub, ZMQ_PUB );

    HttpProcessor proc = new TidProcessor( tid, zmqPublish );
    proc.onLog( "Executing in ASYNC mode" );

    mongrel2ServeImpl( zmqReceive, proc );
}

// ------------------------------------------------------------------------- //

HttpRequest parseMongrelRequest( char[] data )
{
    HttpRequest req = new HttpRequest;

    auto tmp       = findSplitBefore( data, " " );
    req.connection = tmp[ 0 ].idup;
    tmp[ 1 ].popFront(); //skip found space

    tmp            = findSplitBefore( tmp[ 1 ], " " );
    req.connection ~= ":" ~ tmp[ 0 ]; //add connection ID to the end of the sender UUID
    tmp[ 1 ].popFront(); //skip space

    tmp            = findSplitBefore( tmp[ 1 ], " " );
    req.uri        = tmp[ 0 ].idup;
    tmp[ 1 ].popFront(); //skip space

    auto netstr     = parseNetString( tmp[ 1 ] ); //len in netstr[ 0 ], data in netstr[ 1 ]
    auto headerStr  = netstr[ 0 ];
    netstr          = parseNetString( netstr[ 1 ] );
    auto bodyStr    = netstr[ 0 ];

    JSONValue headerJSON = parseJSON( headerStr ); 
    assert( headerJSON != JSONValue.init );
    assert( headerJSON.type == JSON_TYPE.OBJECT );
    foreach( string k, JSONValue v; headerJSON.object )
    {
        string key = capHeaderInPlace( k.dup );

        assert( v.type == JSON_TYPE.STRING );
        req.headers[ key ] ~= v.str;

        if( key == "Method" ) //TODO: Handle JSON method from Mongrel
            req.method = toMethod( req.headers[ key ][ 0 ] );
        else if( key == "Version" )
            req.protocol = req.headers[ key ][ 0 ];
    }

    if( req.method == Method.UNKNOWN && req.headers[ "Method" ][ 0 ] == "JSON" )
    {
        parseJSONBody( bodyStr, req );
        if( isDisconnect( req ) )
        {
            debug writeln( "Disconnect found" );
            return null;
        }
    }
    debug dump( req );
    return req;
}

// ------------------------------------------------------------------------- //

ZMQMsg toMongrelResponse( HttpResponse resp )
{
    //serialise the response as appropriate
    auto buf = appender!( ubyte[] )();
    buf.reserve( 512 + resp.data.length );

    //retrieve the mongrel connection id from the connection identifier
    char[] conn = resp.connection.dup;
    auto tmp = findSplitAfter( conn, ":" );

    if( tmp[ 0 ].empty )
    {
        debug writeln( "Found no mongrel connection id in response connection string " ~ resp.connection );
        return null; //no connection id,
    }

    buf.put( cast( ubyte[] ) zmqIdentity );
    buf.put( ' ' );
    buf.put( cast( ubyte[] ) to!string( tmp[ 1 ].length ) ); //length of following connection id
    buf.put( ':' );
    buf.put( cast( ubyte[] ) tmp[ 1 ] ); //connection id
    buf.put( ',' );
    buf.put( ' ' );

    //now add the HTTP payload
    auto x = toBuffer( resp );
    buf.put( x[ 0 ] );
    //TODO: ignoring x[ 1 ] (ie. needsClose, for now)

    ZMQMsg msg = new ZMQMsg( cast(char[]) buf.data );
    debug dumpHex( cast(char[]) buf.data );
    return msg;
}

// ------------------------------------------------------------------------- //

void parseJSONBody( char[] bodyStr, ref HttpRequest req )
{
    auto jsonBody = parseJSON( bodyStr );
    if( jsonBody == JSONValue.init )
        return;

    foreach( string k, JSONValue v; jsonBody.object )
    {
        req.attrs[ k ] = v.str;
    }
}

// ------------------------------------------------------------------------- //

Tuple!( char[], char[] ) parseNetString( char[] data )
{
    auto tmp = findSplitBefore( data, ":" );
    int len  = to!int( tmp[ 0 ] );
    tmp[ 1 ].popFront(); //skip colon
    assert( tmp[ 1 ][ len ] == ',' );

    return tuple( tmp[ 1 ][ 0 .. len ], tmp[ 1 ][ len + 1 .. $ ] );
}

// ------------------------------------------------------------------------- //

bool isDisconnect( HttpRequest req )
{
    if( req is null )
        return true;

    if( "Method" in req.headers && "type" in req.attrs )
        return req.headers[ "Method" ][ 0 ] == "JSON" &&
                            req.attrs[ "type" ] == "disconnect";
    return false;
}

// ------------------------------------------------------------------------- //

class TidProcessor : protocol.http.TidProcessor
{
    this( Tid tid, ZMQConnection conn )
    {
        super( tid, "[MONGREL2] " );
        zmqConn = conn;
    }

    override bool onIdle()  //return true if we processed something
    {
        receiveTimeout( dur!"usecs"( 0 ),
            ( int i )
            {
                running = ( i != 1 );
            },
            ( HttpResponse resp )
            {
                ZMQMsg msg = toMongrelResponse( resp );
                if( msg !is null )
                    zmqConn.send( msg );
            } );

        return true;
    }

private:

    ZMQConnection zmqConn;
}

// ------------------------------------------------------------------------- //

class DelegateProcessor : protocol.http.DelegateProcessor
{
    this( HttpResponse delegate(HttpRequest) dg, ZMQConnection conn )
    {
        super( dg, "[MONGREL2] " );
        zmqConn = conn;
    }

    override void onRequest( HttpRequest req )
    {
        HttpResponse resp = dg( req );

        if( resp !is null )
        {
            ZMQMsg msg = toMongrelResponse( resp );
            if( msg !is null )
            {
//                onLog( "Sending response length " ~ to!string( msg.length ) );
                zmqConn.send( msg );
            }
        }
    }

private:

    ZMQConnection zmqConn;
}


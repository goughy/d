
module protocol.mongrel2;

import std.ascii;
public import protocol.http;
import std.stdio, std.string, std.conv, std.stdint, std.array, std.range,
       std.datetime, std.algorithm, std.concurrency, std.typecons, std.random, std.utf;
import cjson.cJSON;
import zmq;

string zmqIdentity;

// ------------------------------------------------------------------------- //

void postLog( Tid tid, string s )
{
    send( tid, "[MONGREL2] " ~ s );
}

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

this( string addr, int type )
{
    zmqSock = zmq_socket( zmqCtx, type );
    zmq_connect( zmqSock, addr.toStringz );
}

~this()
{
}

ZMQMsg receive()
{
    ZMQMsg msg = new ZMQMsg();
    zmq_recv( zmqSock, cast( zmq_msg_t* ) msg, 0 );
    return msg;
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

void mongrel2Serve( string address, ushort port, Tid tid )
{
    int major, minor, patch;
    zmq_version( &major, &minor, &patch );
    postLog( tid, format( "zmq_version = %d.%d.%d", major, minor, patch ) );


    char[ 20 ] ident;

    for( auto i = 0; i < 20; ++i )
        ident[ i ] = uniform( 'a', 'z' );

    zmqIdentity = ident.idup;
    writeln( "Identity: ", ident );
//    zmq_setsockopt( zmqReceive, ZMQ_IDENTITY, cast(char *) zmqIdentity.toStringz, zmqIdentity.length );

    string addrPull = format( "tcp://%s:%d", address, port );
    string addrPub  = format( "tcp://%s:%d", address, port - 1 );
    postLog( tid, format( "Pull address %s", addrPull ) );
    postLog( tid, format( "Pub address %s", addrPub ) );
//    zmq_bind( zmqReceive, addr.toStringz );

    ZMQConnection zmqReceive = new ZMQConnection( addrPull, ZMQ_PULL );
    ZMQConnection zmqPublish = new ZMQConnection( addrPub, ZMQ_PUB );

    bool done = false;

    while( !done )
    {
        ZMQMsg msg = zmqReceive.receive();

        if( msg is null )
            continue;

        debug dumpHex( msg.data );

        shared( Request ) req = parseMongrelRequest( msg.data );

        if( req !is null && !isDisconnect( req ) )
            send( tid, req );


        receiveTimeout( dur!"msecs"( 100 ),
                        ( int i )
        {
            done = ( i == 1 );
        },
        ( Response resp )
        {
            debug dump( cast( shared ) resp );
            msg = toMongrelResponse( cast( shared ) resp );

            if( msg !is null )
            {
                zmqPublish.send( msg );
            }
        } );
    }
}

// ------------------------------------------------------------------------- //

void mongrel2Serve( string address, ushort port, shared( Response ) delegate( shared( Request ) ) dg )
{
//    httpServeImpl( address, port, new DelegateProcessor( dg, "[HTTP-D] " ) );
}

// ------------------------------------------------------------------------- //

shared( Request ) parseMongrelRequest( char[] data )
{
    shared( Request ) req = new shared( Request );

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

    //now decode header as JSON packet
    auto headerJSON = cJSON_Parse( headerStr.toStringz );

    //walk the JSON object and build our Request
    int len = cJSON_GetArraySize( headerJSON );

    for( int i = 0; i < len; ++i )
    {
        cJSON * obj = cJSON_GetArrayItem( headerJSON, i );

        if( obj != null )
        {
            string key = capHeader( cast( char[] ) obj.string[ 0 .. std.c.string.strlen( obj.string ) ] );
            req.headers[ key ] =  to!string( obj.valuestring );

            if( key == "Method" ) //TODO: Handle JSON method from Mongrel
                req.method = toMethod( req.headers[ key ] );
            else if( key == "Version" )
                req.protocol = req.headers[ key ];
        }
    }

//    char * s = cJSON_Print( headerJSON );
//    printf( "%s\n", s );
//    std.c.stdlib.free( s );

    if( req.method == Method.UNKNOWN && req.headers[ "Method" ] == "JSON" )
        parseJSONBody( req );

    cJSON_Delete( headerJSON );

    debug dump( req );
    return req;
}

// ------------------------------------------------------------------------- //

ZMQMsg toMongrelResponse( shared( Response ) resp )
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
    auto x = toHttpResponse( resp );
    buf.put( x[ 0 ] );
    //TODO: ignoring x[ 1 ] (ie. needsClose, for now)

    ZMQMsg msg = new ZMQMsg( cast( char[] )buf.data );
    debug dumpHex( cast( char[] ) buf.data );
    return msg;
}

// ------------------------------------------------------------------------- //

void parseJSONBody( ref shared( Request ) req )
{
    //now decode header as JSON packet
    auto json = cJSON_Parse( cast( char* ) req.data.ptr );

    //walk the JSON object and build our Request
    int len = cJSON_GetArraySize( json );

    for( int i = 0; i < len; ++i )
    {
        cJSON * obj = cJSON_GetArrayItem( json, i );

        if( obj != null )
            req.attrs[ to!string( obj.string ) ] =  to!string( obj.valuestring );
    }

    cJSON_Delete( json );
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

bool isDisconnect( shared( Request ) req )
{
    return req is null || ( req.headers[ "Method" ] == "JSON" &&
                            req.attrs[ "type" ] == "disconnect" );
}

// ------------------------------------------------------------------------- //



module protocol.mongrel2;

import std.ascii, std.c.stdlib;
public import protocol.http;
public import protocol.zsocket;
import std.stdio, std.string, std.conv, std.stdint, std.array, std.range,
       std.datetime, std.algorithm, std.concurrency, std.typecons, std.random, std.utf;

import std.json;

string zmqIdentity;
bool running = true;

extern (C) int errno;

// ------------------------------------------------------------------------- //

void mongrel2ServeImpl( ZSocket zmqReceive, HttpProcessor proc )
{
    char[ 20 ] ident;
    for( auto i = 0; i < 20; ++i )
        ident[ i ] = uniform( 'a', 'z' );

    zmqIdentity = ident.idup;
    writeln( "Identity: ", ident );
    zmqReceive.setSockOpt( ZMQ_IDENTITY, ident );

    bool done = false;
    while( !done )
    {
        char[] msg = zmqReceive.receive( ZMQ_DONTWAIT );
        debug dumpHex( msg );

        HttpRequest req = parseMongrelRequest( msg );
        if( req !is null && !isDisconnect( req ) )
            proc.onRequest( req );

        proc.onIdle();
    }
    proc.onExit();
}

// ------------------------------------------------------------------------- //

void mongrel2Serve( string addrPull, string addrPub, RequestDelegate dg )
{
    int major, minor, patch;
    zmq_version( &major, &minor, &patch );

    auto resPull = parseAddr( addrPull, SERVER_PORT );
    auto resPub  = parseAddr( addrPub, SERVER_PORT );

    string pull = format( "tcp://%s:%d", resPull[ 0 ], resPull[ 1 ] );
    string pub  = format( "tcp://%s:%d", resPub[ 0 ], resPub[ 1 ] );

    auto zmqReceive = new ZSocket( pull, ZMQ_PULL );
    auto zmqPublish = new ZSocket( pub, ZMQ_PUB );

    HttpProcessor proc = new DelegateProcessor( dg, zmqPublish );
    proc.onLog( format( "[0MQ %d.%d.%d] Connecting PULL socket to %s", major, minor, patch, pull ) );
    proc.onLog( format( "[0MQ %d.%d.%d] Connecting PUB socket to %s", major, minor, patch, pub ) );
    proc.onLog( "Executing in SYNC mode" );

    mongrel2ServeImpl( zmqReceive, proc );
}

// ------------------------------------------------------------------------- //

void mongrel2Serve( string addrPull, string addrPub, Tid tid )
{
    int major, minor, patch;
    zmq_version( &major, &minor, &patch );

    auto resPull = parseAddr( addrPull, SERVER_PORT );
    auto resPub  = parseAddr( addrPub, SERVER_PORT );

    string pull = format( "tcp://%s:%d", resPull[ 0 ], resPull[ 1 ] );
    string pub  = format( "tcp://%s:%d", resPub[ 0 ], resPub[ 1 ] );

    auto zmqReceive = new ZSocket( pull, ZMQ_PULL );
    auto zmqPublish = new ZSocket( pub, ZMQ_PUB );

    HttpProcessor proc = new TidProcessor( tid, zmqPublish );
    proc.onLog( format( "[0MQ %d.%d.%d] Connecting PULL socket to %s", major, minor, patch, pull ) );
    proc.onLog( format( "[0MQ %d.%d.%d] Connecting PUB socket to %s", major, minor, patch, pub ) );

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

char[] toMongrelResponse( HttpResponse resp )
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

    debug dumpHex( cast(char[]) buf.data );
    return cast(char[]) buf.data.dup;
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
    this( Tid tid, ZSocket conn )
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
                debug writefln( "protocol.mongrel2.TidProcessor::onIdle() received response" );
                if( resp !is null )
                    zmqConn.send( toMongrelResponse( resp ) );
            } );

        return true;
    }

private:

    ZSocket zmqConn;
}

// ------------------------------------------------------------------------- //

class DelegateProcessor : protocol.http.DelegateProcessor
{
    this( HttpResponse delegate(HttpRequest) dg, ZSocket conn )
    {
        super( dg, "[MONGREL2] " );
        zmqConn = conn;
    }

    override void onRequest( HttpRequest req )
    {
        HttpResponse resp = dg( req );

        if( resp !is null )
            zmqConn.send( toMongrelResponse( resp ) );
    }

private:

    ZSocket zmqConn;
}


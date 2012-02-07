
module protocol.mongrel2;

public import protocol.http;
import std.stdio, std.string, std.conv, std.stdint, std.array, std.range,
       std.datetime, std.algorithm, std.concurrency, std.typecons, std.random;
import std.c.time;
import util.logger, util.util;
import cjson.cJSON;
import zmq;

void * zmqContext;
string zmqIdentity;

void postLog( Tid tid, string s )
{
    send( tid, "[MONGREL2] " ~ s );
}

// ------------------------------------------------------------------------- //

void zmqServe( string address, ushort port, Tid tid )
{
    int major, minor, patch;
    zmq_version( &major, &minor, &patch );
    postLog(  tid, format( "zmq_version = %d.%d.%d", major, minor, patch ) );

    zmqContext = zmq_init( 1 );

    void * zmqReceive = zmq_socket( zmqContext, ZMQ_PULL );

    char[ 20 ] ident;
    for( auto i = 0; i < 20; ++i )
        ident[ i ] = uniform( 'a', 'z' );

    zmqIdentity = ident.idup;
    writeln( "Identity: ", ident );
    zmq_setsockopt( zmqReceive, ZMQ_IDENTITY, cast(char *) zmqIdentity.toStringz, zmqIdentity.length );

    void * zmqPublish = zmq_socket( zmqContext, ZMQ_PUB );

    string addrPull = format( "tcp://%s:%d", address, port );
    string addrPub  = format( "tcp://%s:%d", address, port - 1 );
    postLog( tid, format( "Pull address %s", addrPull ) );
    postLog( tid, format( "Pub address %s", addrPub ) );
//    zmq_bind( zmqReceive, addr.toStringz );

    zmq_connect( zmqReceive, addrPull.toStringz );
    zmq_connect( zmqPublish, addrPub.toStringz );

    bool done = false;
    while( !done )
    {
        zmq_msg_t * msg = cast(zmq_msg_t *) std.c.stdlib.malloc( zmq_msg_t.sizeof );
        zmq_msg_init( msg );
        zmq_recv( zmqReceive, msg, 0 );

        char[] data;
        data.length = zmq_msg_size( msg );
        std.c.string.memcpy( data.ptr, zmq_msg_data( msg ), data.length );
        std.c.stdlib.free( msg );
        debug dumpHex( data );

        Request req = parseMongrelRequest( data );
        if( req !is null )
            send( tid, req );


        receiveTimeout( dur!"msecs"( 10 ),
                ( int i )
                {
                    switch( i )
                    {
                        case 1:
                            done = true;
                            break;

                        default:
                            break;
                    }
                },
                ( Response resp ) 
                { 
                    debug dump( resp );
                    msg = toMongrelResponse( resp );
                    if( msg !is null )
                    {
                        zmq_send( zmqPublish, msg, 0 ); //send it off
                        std.c.stdlib.free( msg );
                    }
                } );
    }
}

// ------------------------------------------------------------------------- //

void zmqServe( string address, ushort port, Response delegate(Request) dg )
{
//    httpServeImpl( address, port, new DelegateProcessor( dg, "[HTTP-D] " ) );
}

// ------------------------------------------------------------------------- //

Request parseMongrelRequest( char[] data )
{
    Request req = new Request();

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
            string key = capHeader( cast(char[]) obj.string[ 0 .. std.c.string.strlen( obj.string ) ] );
            req.headers[ key ] =  to!string( obj.valuestring );
            if( key == "Method" )
                req.method = toMethod( req.headers[ key ] );
            else if( key == "Version" )
                req.protocol = req.headers[ key ];
        }
    }

//    char * s = cJSON_Print( headerJSON );
//    printf( "%s\n", s );
//    std.c.stdlib.free( s );
    cJSON_Delete( headerJSON );

    debug dump( req );
    return req;
}

// ------------------------------------------------------------------------- //

zmq_msg_t * toMongrelResponse( Response resp )
{
    //serialise the response as appropriate
    auto buf = appender!(ubyte[])();
    buf.reserve( 512 );

    //retrieve the mongrel connection id from the connection identifier
    char[] conn = resp.connection.dup;
    auto tmp = findSplitAfter( conn, ":" );
    if( tmp[ 0 ].empty )
    {
        debug writeln( "Found no mongrel connection id in response connection string " ~ resp.connection );
        return null; //no connection id, 
    }

    buf.put( cast(ubyte[]) zmqIdentity );
    buf.put( ' ' );
    buf.put( cast(ubyte[]) to!string( tmp[ 1 ].length ) ); //length of following connection id
    buf.put( ':' );
    buf.put( cast(ubyte[]) tmp[ 1 ] ); //connection id
    buf.put( ',' );
    buf.put( ' ' );

    //now add the HTTP payload
    buf.put( cast(ubyte[]) "HTTP/1.1 " );
    buf.put( cast(ubyte[]) to!string( resp.statusCode ) );
    buf.put( ' ' );
    buf.put( cast(ubyte[]) resp.statusMesg );
    buf.put( '\r' );
    buf.put( '\n' );

    resp.addHeader( "Server", SERVER_HEADER );
    if( ("Date" in resp.headers) is null )
    {
        long now = time( null );
        resp.addHeader( "Date", to!string( asctime( gmtime( & now ) ) )[0..$-1] );
    }

    if( ("Connection" in resp.headers) !is null )
    {
        if( resp.protocol.toLower == "http/1.0" )
            resp.addHeader( "Connection", "Keep-Alive" );
    }

    if( ("Content-Length" in resp.headers) is null )
        resp.addHeader( "Content-Length", to!string( resp.data.length ) );

    foreach( k,v; resp.headers )
    {
        buf.put( cast(ubyte[]) k );
        buf.put( ':' );
        buf.put( ' ' );
        buf.put( cast(ubyte[]) v );
        buf.put( '\r' );
        buf.put( '\n' );
    }

    buf.put( '\r' );
    buf.put( '\n' );
    if( resp.data.length > 0 )
        buf.put( cast(ubyte[]) resp.data );

    zmq_msg_t * msg = cast(zmq_msg_t *) std.c.stdlib.malloc( zmq_msg_t.sizeof );
    zmq_msg_init_size( msg, buf.data.length );
    std.c.string.memcpy( zmq_msg_data( msg ), buf.data.ptr, buf.data.length );
    debug dumpHex( cast(char[]) buf.data );
    return msg;
}

// ------------------------------------------------------------------------- //

Tuple!(char[], char[]) parseNetString( char[] data )
{
    auto tmp = findSplitBefore( data, ":" );
    int len  = to!int( tmp[ 0 ] );
    tmp[ 1 ].popFront(); //skip colon
    assert( tmp[ 1 ][ len ] == ',' );

    return tuple( tmp[ 1 ][ 0 .. len ], tmp[ 1 ][ len + 1 .. $ ] );
}

// ------------------------------------------------------------------------- //


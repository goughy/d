
module protocol.http;

import std.string, std.concurrency, std.uri, std.conv, std.stdio, std.ascii;
import std.socket, std.algorithm, std.typecons, std.array, std.c.time;
import util.util;

import core.sys.posix.signal;
import zmq;

enum Method { UNKNOWN, OPTIONS, GET, HEAD, POST, PUT, DELETE, TRACE, CONNECT };

enum TIMEOUT_USEC   = 1000;
enum CHUNK_SIZE     = 1024; //try to get at least Content-Length header in first chunk
bool running        = false;

enum SERVER_HEADER  = "Server";
enum SERVER_DESC    = "HTTP-D/1.0";
enum NEWLINE        = "\r\n";
enum HTTP_10        = "HTTP/1.0";
enum HTTP_11        = "HTTP/1.1";

// --------------------------------------------------------------------------------

shared class Request
{
public:

    this( string id = "" )
    {
        connection = id;
    }

    string          connection;
    Method          method;
    string          protocol;
    string          uri;
    string[string]  headers;
    string[string]  attrs;
    ubyte[]         data;

    string getHeader( string k )
    {
        return headers[ capHeader( k.dup ) ];
    }

    string getAttr( string k )
    {
        return attrs[ k.toLower ];
    }

    shared(Response) getResponse()
    {
        shared Response resp = cast(shared) new Response( connection, protocol ); //bind the response to the reqest connection
        if( "Connection" in headers )
            resp.addHeader( "Connection", getHeader( "Connection" ) );

        return resp;
    }
}

// ------------------------------------------------------------------------- //

shared class Response
{
public:
    
    this( string id = "", string proto  = "" )
    {
        connection = id;
        protocol = proto;
    }

    string          connection;
    string          protocol;
    int             statusCode;
    string          statusMesg;
    string[string]  headers;
    ubyte[]         data;

    shared(Response) addHeader( string k, string v )
    {
        headers[ capHeader( k.dup ) ] = v;
        return this;
    }
}

// ------------------------------------------------------------------------- //

interface HttpProcessor
{
    void onInit();
    void onLog( string s );
    void onRequest( shared(Request) req );
    bool onIdle();  //return true if we processed something
    void onExit();
}

// ------------------------------------------------------------------------- //

HttpConnection[int] httpConns;

class HttpConnection
{
public:

    this( Socket s )
    {
        sock = s;
        ident = sock.remoteAddress().toString();
//        ident = to!string( cast(int) sock.handle() );
    }

    ~this()
    {
        debug writefln( "Destroying connection fd %d", sock.handle() );
    }

    @property string id()       { return ident; }
    @property Socket socket()   { return sock; }

    void close()
    {
        try
        {
            sock.close();
        }
        catch( Throwable t ) {} //ignored
    }

    shared(Request) read()
    {
        ubyte[] buf;
        buf.length = CHUNK_SIZE;
        long num = sock.receive( buf ); //may propogate read exception
        if( num > 0 )
        {
            buf.length = num;
            readBuf ~= buf;
            debug dumpHex( cast(char[]) buf, "(D) read data (num = " ~to!string( num ) ~ ")" );
            auto resp = parseHttpHeaders( readBuf );
            if( resp[ 1 ] == 0 ) //no more data necessary
            {
                readBuf.length = 0;
                resp[ 0 ].connection = to!string( id );
                return resp[ 0 ]; //return null if we have more data to read...
            }
        }
        else if( num == 0 )
            throw new SocketException( "EOF on " ~ to!string( id ) ~ " (" ~ to!string( num ) ~ " bytes read)" );
        else
            throw new SocketException( "Error on " ~ to!string( id ) ~ " (returned " ~ to!string( num ) ~ ")" );

        return null;
    }

    ulong write()
    {
        ulong num = sock.send( writeBuf );
        if( num == writeBuf.length )
            writeBuf.length = 0;
        else
            writeBuf = writeBuf[ num .. $ ];

        debug writefln( "(D) Wrote %d bytes (%d left) to connection %s", num, writeBuf.length, id );
        return num;
    }

    void add( shared(Response) r )
    {
        writeBuf ~= toHttpResponse( r );
        debug writefln( "(D) Added response to connection %s, writeBuf length %d", id, writeBuf.length );

    }

    @property bool needsWrite() { return writeBuf.length > 0UL; }

private:

    string  ident;
    ubyte[] readBuf;
    ubyte[] writeBuf;
    Socket  sock;
}

// ------------------------------------------------------------------------- //

private void httpServeImpl( string address, ushort port, HttpProcessor proc )
{
    proc.onInit();
    running = true;

    InternetAddress bindAddr = new InternetAddress( address, port );


    //set up our listening socket...
    Socket listenSock = new Socket( AddressFamily.INET, SocketType.STREAM );
    try
    {
        listenSock.blocking( false );
        listenSock.bind( bindAddr );
        listenSock.listen( 100 );

        proc.onLog( "Listening on " ~ bindAddr.toString() ~ ", fd " ~ to!string( cast(int) listenSock.handle() ) ~ ", queue length 100" );
    }
    catch( Throwable t )
    {
        proc.onLog( "Exception configuring listen listenSock: " ~ t.toString() );
        return;
    }

    zmq_pollitem_t * listenItem()
    {
        zmq_pollitem_t * item = new zmq_pollitem_t;
        item.fd     = listenSock.handle();
        item.events = ZMQ_POLLIN;

        return item;
    }

    zmq_pollitem_t * connItem( HttpConnection * pConn ) 
    { 
        zmq_pollitem_t * item = new zmq_pollitem_t;
        item.fd     = pConn.socket.handle();
        item.events = ZMQ_POLLIN;
        if( pConn.needsWrite )
            item.events |= ZMQ_POLLOUT;

        return item;
    }

    /+++====++/
    bool isListener( zmq_pollitem_t * item ) { return item.fd == listenSock.handle(); }

    /+++====++/
    bool onError( HttpConnection * pConn )
    {
        debug proc.onLog( "Error on connection " ~ to!string( pConn.id ) ~ " - closing" );
        return false;
    }

    /+++====++/
    HttpConnection onAccept()
    {
        try
        {
            Socket client = listenSock.accept();
            client.blocking( false );
            client.setOption( SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1 );

            debug writefln( "(D) onAccept() new client fd %d - %s", cast(int) client.handle(), client.remoteAddress().toString() );
            HttpConnection conn = new HttpConnection( client );
            httpConns[ client.handle() ] = conn;
            return conn;
        }
        catch( SocketAcceptException sae )
        {
//            debug writefln( "(D) onAccept(): %s", sae.toString() );
        }
        return null;
    }

    /+++====++/
    bool onRead( HttpConnection * pConn )
    {
        debug writefln( "(D) Reading from connection %s", pConn.id );
        shared(Request) req = pConn.read();
        if( req !is null )
            proc.onRequest( req );

        return true;
    }

    /+++====++/
    bool onWrite( HttpConnection * pConn )
    {
        return pConn.write() > 0L;
    }

    /+++====++/
    void onClose( HttpConnection * pConn )
    {
        httpConns.remove( pConn.sock.handle() );
        pConn.close();
    }

    HttpConnection tmp;

    zmq_pollitem_t pitem[];
    zmq_pollitem_t ptmp[];

    pitem ~= *listenItem();

    bool receivedData = false;
    while( running )
    {
        ptmp.length = 0;

        int num = zmq_poll( pitem.ptr, cast(int) pitem.length, receivedData ? 0 : TIMEOUT_USEC / 1000 );
        if( num > 0 || receivedData )
        {
            for( long i = 0; i < pitem.length; i++ )
            {
                bool keep = true;
                debug writefln( "(D) pitem[ %d ], fd %d, events %d, revents %d", 
                        i, pitem[ i ].fd, pitem[ i ].events, pitem[ i ].revents );

                HttpConnection * pConn = pitem[ i ].fd in httpConns;
                try
                {
                    //handle listen socket
                    if( pitem[ i ].fd == listenSock.handle() )
                    {
                        if( (pitem[ i ].revents & ZMQ_POLLERR) != 0 )
                        {
                            proc.onLog( "Error on listen socket - aborting" );
                            running = false;
                        }
                        else if( (pitem[ i ].revents & ZMQ_POLLIN) != 0 )
                        {
                            tmp = onAccept();
                            if( tmp !is null )
                                pConn = &tmp;
                        }
                        ptmp ~= *listenItem(); //keep the listen socket in the runlist
                    }
                    else //handle normal sockets
                    {
                        //error checking
                        if( (pitem[ i ].revents & ZMQ_POLLERR) != 0 )
                            keep = false; // onError( pConn );
                        else
                        {
                            //read checking
                            if( (pitem[ i ].revents & ZMQ_POLLIN) != 0 )
                                keep = onRead( pConn );

                            //write checking
                            if( (pitem[ i ].revents & ZMQ_POLLOUT) != 0 )
                                keep = onWrite( pConn );
                        }
                    }
                }
                catch( SocketException e )
                {
                    debug proc.onLog( "Exception occurred on fd " ~ to!string( pitem[ i ].fd ) ~ 
                            ", error " ~ to!string( e.errorCode )  ~ " - " ~ e.toString() );
                    keep = false;
                }

                //merge runlist
                if( pConn !is null )
                {
                    if( keep )
                        ptmp ~= *connItem( pConn );
                    else
                        onClose( pConn );
                }
            }
            debug writefln( "(D) Swapping runlist old[ %d ] <- new[ %d ]", pitem.length, ptmp.length );
            pitem = ptmp;
//            foreach( i, z; pitem )
//                debug writefln( "\tpitem[ %d ], fd %d, events %d, revents %d, socket %x", 
//                    i, z.fd, z.events, z.revents, z.socket );

        }

        //do idle processing
        receivedData = proc.onIdle();
    }

    proc.onExit();
}

// ------------------------------------------------------------------------- //

/**
 * Thread entry point for HTTP processing
 */

void httpServe( string address, ushort port, Tid tid )
{
    httpServeImpl( address, port, new TidProcessor( tid, "[HTTP-D] " ) );
}

// ------------------------------------------------------------------------- //

void httpServe( string address, ushort port, shared(Response) delegate(shared(Request)) dg )
{
    httpServeImpl( address, port, new DelegateProcessor( dg, "[HTTP-D] " ) );
}

// ------------------------------------------------------------------------- //

class TidProcessor : HttpProcessor
{
public:

    this( Tid t, string logPrefix = "[HTTP] " )
    {
        tid = t;
        prefix = logPrefix;
    }

    void onInit()
    {
        onLog( "Protocol initialising (ASYNC mode)" );
    }

    void onLog( string s )
    {
        if( tid != Tid.init )
            send( tid, prefix ~ s );
    }

    void onExit()
    {
        onLog( "Protocol exiting (ASYNC mode)" );
    }

    void onRequest( shared(Request) req )
    {
        send( tid, req );
    }

    bool onIdle()
    {
        bool found = false;

        receiveTimeout( dur!"usecs"(TIMEOUT_USEC), 
                ( int i )
                {
                    running = (i != 1);
                },
                ( shared(Response) resp ) 
                { 
                    foreach( conn; httpConns )
                    {
                        if( conn.id == resp.connection )
                        {
                            conn.add( resp );
                            found = true;
                            break;
                        }
                    }
                } );

        return found;
    }

private:

    Tid tid;
    string prefix;
}

// ------------------------------------------------------------------------- //

class DelegateProcessor : HttpProcessor
{
public:

    this( shared(Response) delegate(shared(Request)) d, string logPrefix = "[HTTP] " )
    {
        dg = d;
        prefix = logPrefix;
    }

    void onInit()
    {
        onLog( "Protocol initialising (SYNC mode)" );
    }

    void onLog( string s )
    {
        writeln( prefix ~ s );
    }

    void onExit()
    {
        onLog( "Protocol exiting (SYNC mode)" );
    }

    void onRequest( shared(Request) req )
    {
        shared Response resp = dg( req );
        if( resp !is null )
        {
            debug writefln( "(D) processing received response" );
            foreach( conn; httpConns )
            {
                if( conn.id == resp.connection )
                {
                    conn.add( resp );
                    hadData = true;
                    break;
                }
            }
        }
    }

    bool onIdle()
    {
        //noop for sync
        bool tmp = hadData;
        hadData = false;
        return tmp;
    }

private:

    shared(Response) delegate(shared(Request)) dg;
    string prefix;
    bool   hadData;
}

// ------------------------------------------------------------------------- //

Method toMethod( string m )
{
    //enum Method { UNKNOWN, OPTIONS, GET, HEAD, POST, PUT, DELETE, TRACE, CONNECT };
    switch( m.toLower() )
    {
        case "get":
            return Method.GET;
        case "post":
            return Method.POST;
        case "head":
            return Method.HEAD;
        case "options":
            return Method.OPTIONS;
        case "put":
            return Method.PUT;
        case "delete":
            return Method.DELETE;
        case "trace":
            return Method.TRACE;
        case "connect":
            return Method.CONNECT;
        default:
            break;
    }

    return Method.UNKNOWN;
}

// ------------------------------------------------------------------------- //

zmq_pollitem_t * toZmqItem( HttpConnection c )
{
    zmq_pollitem_t * i = new zmq_pollitem_t;
    i.fd     = c.socket.handle();
    i.events = ZMQ_POLLIN;

    return i;
}

// ------------------------------------------------------------------------- //

Tuple!(shared(Request),ulong) parseHttpHeaders( ubyte[] buf )
{
    shared Request req = new shared(Request)();
    ulong reqLen = 0UL;
    
    auto res = findSplit( buf, NEWLINE );
    //first line should be OP URL PROTO
    auto line  = splitter( res[ 0 ], ' ' );

    req.method = toMethod( (cast(char[]) line.front).idup );
    line.popFront;
    req.uri    = (cast(char[]) line.front).idup;
    line.popFront;
    req.protocol = (cast(char[]) line.front).idup;

//    writefln( "Length of remaining buffer is %d", res[ 2 ].length );
    for( res = findSplit( res[ 2 ], NEWLINE ); res[ 0 ].length > 0; )
    {
        auto hdr = findSplit( res[ 0 ], ": " );
//        debug writefln( "Header split = %s: %s", to!string( hdr[ 0 ] ), to!string( hdr[ 2 ] ) );
        if( hdr.length > 0 )
        {
            string key = capHeader( (cast(char[]) hdr[ 0 ]) ).idup; 
            string val = (cast(char[]) hdr[ 2 ]).idup;

            req.headers[ key ] = val;
            if( key == "Content-Length" )
                reqLen = to!ulong( val );
        }
        res = findSplit( res[ 2 ], NEWLINE );
    }

    req.data = cast(shared ubyte[]) res[ 2 ];
    debug dumpHex( cast(char[]) req.data, "HTTP REQUEST" );
    return tuple( req, reqLen - req.data.length );
}

// ------------------------------------------------------------------------- //

ubyte[] toHttpResponse( shared(Response) r )
{
    auto buf = appender!(ubyte[])();
    buf.reserve( 512 );

    buf.put( cast(ubyte[]) HTTP_11 );
    buf.put( ' ' );

    buf.put( cast(ubyte[]) to!string( r.statusCode ) );
    buf.put( ' ' );
    buf.put( cast(ubyte[]) r.statusMesg );
    buf.put( '\r' );
    buf.put( '\n' );

    r.addHeader( SERVER_HEADER, SERVER_DESC );
    if( !("Date" in r.headers) )
    {
        long now = time( null );
        r.addHeader( "Date", to!string( asctime( gmtime( & now ) ) )[0..$-1] );
    }

    if( "Connection" in r.headers )
    {
        if( r.protocol.toUpper == HTTP_10 )
            r.addHeader( "Connection", "Keep-Alive" );
    }

    if( !("Content-Length" in r.headers) && !isChunked( r ) )
        r.addHeader( "Content-Length", to!string( r.data.length ) );

    foreach( k,v; r.headers )
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
    if( r.data.length > 0 )
        buf.put( cast(ubyte[]) r.data );

    debug dumpHex( cast(char[]) buf.data, "HTTP RESPONSE" );
    return buf.data;
}

// ------------------------------------------------------------------------- //

void dump( shared(Request) r )
{
    writeln( "Connection: ", r.connection.idup );
    writeln( "Method    : ", r.method );
    writeln( "Protocol  : ", r.protocol.idup );
    writeln( "URI       : ", r.uri.idup );

    foreach( k, v; r.headers )
        writeln( "\t", k.idup, ": ", v.idup );

    foreach( k, v; r.attrs )
        writeln( "\t", k.idup, ": ", v.idup );
}

// ------------------------------------------------------------------------- //

void dump( shared(Response) r, string title = "" )
{
    if( title.length > 0 )
        writeln( title );

    writeln( "Connection: ", r.connection.idup );
    writeln( "Status    : ", r.statusCode, " ", r.statusMesg.idup );

    foreach( k, v; r.headers )
        writeln( "\t", k.idup, ": ", v.idup );

    dumpHex( cast(char[]) r.data );
}

// ------------------------------------------------------------------------- //

string capHeader( char[] hdr )
{
    bool up = true; //uppercase first letter
    foreach( i, char c; hdr ) 
    {
        if( isAlpha( c ) )
        {
            hdr[ i ] = cast(char)(up ? toUpper( c ) : toLower( c ));
            up = false;
        }
        else
            up = true;
    }
    return hdr.idup;
}

// ------------------------------------------------------------------------- //

bool isChunked(T)( T r )
{
    return "Transfer-Encoding" in r.headers &&
        r.headers[ "Transfer-Encoding" ].toLower == "chunked";
}

// ------------------------------------------------------------------------- //

ulong hexToULong( ubyte[] d )
{
    ulong val = 0;
    int pow = 1;
    foreach( u; std.range.retro( d ) )
    {
        val += (isDigit( u ) ? u - '0' : u - ('A' - 10) ) * pow;
        pow *= 16;
    }
    return val;
}

unittest
{
    assert( hexToULong( ['3','1','C'] ) == 796 );
}

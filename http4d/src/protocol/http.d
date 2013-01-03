/**

HTTP4D provides an easy entry point for providing embedded HTTP support
into any D application.

This module provides a simple HTTP implementation

License: $(LINK2 http://boost.org/LICENSE_1_0.txt, Boost License 1.0).

Authors: $(LINK2 https://github.com/goughy, Andrew Gough)

Source: $(LINK2 https://github.com/goughy/d/tree/master/http4d, github.com)
*/


module protocol.http;

import std.string, std.concurrency, std.uri, std.conv, std.stdio, std.ascii;
import std.socket, std.algorithm, std.typecons, std.array, std.c.time, std.datetime;

import core.sys.posix.signal, core.sys.posix.stdlib;
import zmq;

public import protocol.httpapi;
public import protocol.zsocket;

enum MAX_REQUEST_LEN = 1024 * 1024 * 20; // 20MB
enum DIVERT_REQUEST_LEN = 1024 * 30; // 50kB

enum TIMEOUT_MSEC   = 0;
enum CHUNK_SIZE     = 8096; //try to get at least Content-Length header in first chunk
bool running        = false;

enum SERVER_HEADER  = "Server";
enum SERVER_DESC    = "HTTP4D/1.0";
enum NEWLINE        = "\r\n";
enum HTTP_10        = "HTTP/1.0";
enum HTTP_11        = "HTTP/1.1";
enum SERVER_ADMIN   = "root";
enum SERVER_HOST    = "localhost.localdomain";
enum SERVER_PORT    = 8080;
enum USER_AGENT     = SERVER_DESC ~ " (" ~ __VENDOR__ ~ " " ~ to!string( __VERSION__ ) ~ ")";

/**
 * Delegate signature required to be implemented by any handler
 */

alias shared(Response) delegate(shared(Request)) RequestDelegate;

// ------------------------------------------------------------------------- //

class HttpException : Exception
{
public:

    this( int code = 400 )
    {
        super( StatusCodes[ code ] );
        statusCode = code;
    }

    @property int code() { return statusCode; }

    HttpResponse getResponse()
    {
        HttpResponse resp = new HttpResponse();
        resp.addHeader( "Connection", "close" );
        resp.protocol   = HTTP_11;
        resp.statusCode = statusCode;
        resp.statusMesg = StatusCodes[ statusCode ];

        return resp;
    }

private:

    int statusCode;
}

// ------------------------------------------------------------------------- //

/**
 * Synchronous HTTP request handler entry point.  Once executed, control
 * of the event loop stays in the library and control only returns to 
 * user code via the execution of the provided delegate.  This interface
 * provides the lowest execution overhead (as opposed to the asynchronous
 * interface below).
 * Example:
 * ---
 * import std.stdio;
 * import protocol.http;
*
* int main( string[] args )
*
{
    *     httpServe( "127.0.0.1:8888",
    * ( req ) => req.getResponse().
    *                             status( 200 ).
    *                             header( "Content-Type", "text/html" ).
    *                             content( "<html><head></head><body>Processed ok</body></html>" ) );
    *     return 0;
    *
}
* ---
*/

void httpServe( string bindAddr, RequestDelegate dg )
{
    auto res = parseAddr( bindAddr, SERVER_PORT );
    HttpProcessor proc = new DelegateProcessor( dg, "[HTTP-D] " );
    proc.onLog( "Executing in SYNC mode" );
    httpServeImpl( res[ 0 ], res[ 1 ], proc );
}

// ------------------------------------------------------------------------- //

/**
 * Asynchronous thread entry point for HTTP processing.  This interface requires
 * a $(D_PSYMBOL Tid) with a $(D_PSYMBOL Request) delegate clause.
 *
 * Example:
 * ---
 * import std.stdio, std.concurrency;
 * import protocol.http;
 *
 * int main( string[] args )
 * {
 *     Tid tid = spawnLinked( httpServe, "127.0.0.1:8888", thisTid() );
 *
 *     bool shutdown = false;
 *     while( !shutdown )
 *     {
 *         try
 *         {
 *             receive(
 *                 ( shared(Request) req )
 *                 {
 *                     send( tid, handleReq( req ) );
 *                 },
 *                 ( LinkTerminated e ) { shutdown = true; }
 *            );
 *        }
 *        catch( Throwable t )
 *        {
 *            writefln( "Caught exception waiting for msg: " ~ t.toString );
 *        }
 *    }
 * }
 *
 * shared(Response) handleReq( shared(Request) req )
 * {
 *      return req.getResponse().
 *              status( 200 ).
 *              header( "Content-Type", "text/html" ).
 *              content( "<html><head></head><body>Processed ok</body></html>" );
 * }
 *
 * ---
 */

void httpServe( string bindAddr, Tid tid )
{
    auto res = parseAddr( bindAddr, SERVER_PORT );
    HttpProcessor proc = new TidProcessor( tid, "[HTTP-D] " );
    proc.onLog( "Executing in ASYNC mode" );
    httpServeImpl( res[ 0 ], res[ 1 ], proc );
}

// ------------------------------------------------------------------------- //

void httpServe( string bindAddr, string zmqIPCAddr )
{
    auto res = parseAddr( bindAddr, SERVER_PORT );
    HttpProcessor proc = new ZmqProcessor( zmqIPCAddr, "[HTTP-D] " );
    proc.onLog( "Executing in ZMQ mode" );
    httpServeImpl( res[ 0 ], res[ 1 ], proc );
}

// ------------------------------------------------------------------------- //

HttpResponse httpClient( string url )
{
   Uri u = Uri( url );
   if( u.scheme != "http" )
       throw new Exception( "Unsupported URI scheme: " ~ u.scheme );

   HttpRequest req = new HttpRequest;
   req.method   = Method.GET;
   req.protocol = HTTP_11; //auto-close
   req.uri      = u.path;

   req.headers[ "Host" ]       ~= u.host ~ ":" ~ to!string( u.port );
   req.headers[ "User-Agent" ] ~= USER_AGENT;
   return httpClient( req );
}

// ------------------------------------------------------------------------- //

int responseId = 0;

HttpResponse httpClient( HttpRequest req )
{
    assert( req !is null );
    assert( req.uri !is null );
    assert( "Host" in req.headers );

    auto addrRes = parseAddr( req.getHeader( "Host" )[ 0 ], 80 );
//    debug req.dump( "HTTPCLIENT request" );

    InternetAddress addr = new InternetAddress( addrRes[ 0 ], addrRes[ 1 ] );
    Socket sock = new Socket( AddressFamily.INET, SocketType.STREAM );
    sock.blocking( true );
    sock.setOption( SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1 );
    sock.connect( addr );

    ubyte[] reqData = toBuffer( req );
    auto len = sock.send( reqData );

    ubyte[] buf;
    buf.length = CHUNK_SIZE;
    long num = sock.receive( buf ); //may propogate read exception
    if( num > 0 )
    {
        buf.length = num;
        auto res = parseHttpHeaders( buf );
        auto currReq = res[ 0 ];
        auto rem     = res[ 1 ];
        while( rem > currReq.data.length )
        {
            buf.length = rem;
            num = sock.receive( buf );
            if( num > 0 )
                rem = onHttpData( currReq, buf );
            else
                throw new Exception( "EOF exception when attempting to receive next " ~ to!string( rem ) ~ " bytes" );
        }
        
        sock.close();

        currReq.connection = addr.toString();

        HttpResponse resp = currReq.getResponse();
        resp.statusCode   = to!int( currReq.uri );
        resp.statusMesg   = currReq.protocol;
        resp.headers = currReq.headers;
        resp.data    = currReq.data;

//        debug resp.dump( "RESPONSE " ~ addrRes[ 0 ] ~ ": " ~ to!string( responseId++ ) );
        return resp;
    }
    return null;
}

// ------------------------------------------------------------------------- //

interface HttpProcessor
{
    void onInit();
    void onLog( string s );
    void onRequest( shared( Request ) req );
    bool onIdle();  //return true if we processed something
    void onExit();
}

// ------------------------------------------------------------------------- //

ulong[string] httpStats;

private void addStat( string s, ulong num )
{
    if( auto p = s in httpStats )
        (*p) += num;
    else
        httpStats[ s ] = num;
}

private void incStat( string s )
{
    addStat( s, 1 );
}

private void setStat( string s, ulong num )
{
    httpStats[ s ] = num;
}

void showStats()
{
    foreach( k,v; httpStats )
        writefln( "\t%s = %u", k, v );
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
        currReq = null;
        state = State.Headers;
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

    HttpRequest read()
    {
        if( state == State.Closing )
            return null;

        ubyte[] buf;
        buf.length = CHUNK_SIZE;
        long num = sock.receive( buf ); //may propogate read exception
        if( num <= 0 )
            throw new SocketException( (num < 0 ? "Error" : "EOF") ~ " on " ~ to!string( id ) ~ " (" ~ to!string( num ) ~ " bytes read)" );

        auto rem = 0UL;
        buf.length = num;
        addStat( "total_bytes_read", num );
        if( state == State.Headers )
        {
            int pos = -1;
            if( readBuf.length == 0 )
            {
                pos = findEndOfHeaders( buf );
                if( pos <= 0 )
                {
                    //if we didn't find the end of the headers from this read, store the data and read again
                    readBuf ~= buf;
                }
            }
            else
            {
                // this is any read > 1 to attempt to find the end of the headers
                readBuf ~= buf[ 0 .. num ];
                pos = findEndOfHeaders( readBuf );
            }

            if( pos >= 0 )
            {
                state = State.Body;

                auto res = parseHttpHeaders( buf );
                currReq = res[ 0 ];
                rem     = res[ 1 ];
            }
        }
        else if( state == State.Body )
        {
            rem = onHttpData( currReq, buf );
        }

        if( rem <= 0UL && currReq !is null ) //no more data necessary
        {
            incStat( "total_requests" );
            incStat( "total_requests_" ~ to!string( currReq.method ).toLower );

            currReq.connection = to!string( id );
            currReq.attrs[ "Remote-Host" ]  = currReq.connection;
            currReq.attrs[ "Server-Admin" ]  = SERVER_ADMIN;
            currReq.attrs[ "Server-Host" ]  = SERVER_HOST;

            HttpRequest tmp = currReq;
            currReq = null;
            readBuf.length = 0;
            state = State.Headers;

            return tmp; //return null if we have more data to read...
        }

        return null;
    }

    ulong write()
    {
        ulong num = sock.send( writeBuf );
        addStat( "total_bytes_written", num );
        if( num == writeBuf.length )
            writeBuf.length = 0;
        else
            writeBuf = writeBuf[ num .. $ ];

        return num;
    }

    void add( shared( Response ) r )
    {
        incStat( "total_responses" );
        auto x = toBuffer( r, isChunked( r ) );
        writeBuf ~= x[ 0 ];
        state = x[ 1 ] ? State.Closing : State.Headers;
    }

    @property bool needsWrite() { return writeBuf.length > 0UL; }
    @property bool needsClose() { return state == State.Closing; }

private:

    string  ident;
    ubyte[] readBuf;
    ubyte[] writeBuf;
    Socket  sock;
    enum State { Headers, Body, Closing };
    State    state;
    HttpRequest currReq;
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

        proc.onLog( "Listening on " ~ bindAddr.toString() ~ ", fd " ~ to!string( cast( int ) listenSock.handle() ) ~ ", queue length 100" );
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

    //++ += == = ++/
    bool isListener( zmq_pollitem_t item ) { return item.fd == listenSock.handle; }

    //++ += == = ++/
    HttpConnection onAccept()
    {
        try
        {
            Socket client = listenSock.accept();
            client.blocking( false );
            client.setOption( SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1 );

            HttpConnection conn = new HttpConnection( client );
            httpConns[ client.handle() ] = conn;
            incStat( "num_accepted" );
            return conn;
        }
        catch( SocketAcceptException sae )
        {
        }

        return null;
    }

    //++ += == = ++/
    bool onRead( HttpConnection * pConn )
    {
        HttpRequest req = pConn.read();
        if( req !is null )
            proc.onRequest( req );

        return true;
    }

    //++ += == = ++/
    bool onWrite( HttpConnection * pConn )
    {
        return pConn.write() > 0L;
    }

    //++ += == = ++/
    void onClose( HttpConnection * pConn )
    {
        httpConns.remove( pConn.sock.handle() );
        pConn.close();
    }

    HttpConnection tmp;

    zmq_pollitem_t pitem[];
    zmq_pollitem_t ptmp[];

    pitem ~= *listenItem();

    proc.onLog( "Server max request length " ~ to!string( MAX_REQUEST_LEN ) ~ ", divert length " ~ to!string( DIVERT_REQUEST_LEN ) );
    bool receivedData = false;

    while( running )
    {
        ptmp.length = 0;

        int num = zmq_poll( pitem.ptr, cast( int ) pitem.length, receivedData ? 0 : TIMEOUT_MSEC );
        if( num > 0 || receivedData )
        {
            for( long i = 0; i < pitem.length; i++ )
            {
                bool keep = true;
//                debug writefln( "(D) pitem[ %d ], fd %d, events %d, revents %d",
//                        i, pitem[ i ].fd, pitem[ i ].events, pitem[ i ].revents );

                HttpConnection * pConn = pitem[ i ].fd in httpConns;

                try
                {
                    //handle listen socket
                    if( isListener( pitem[ i ] ) )
                    {
                        if( ( pitem[ i ].revents & ZMQ_POLLERR ) != 0 )
                        {
                            proc.onLog( "Error on listen socket - aborting" );
                            running = false;
                        }
                        else if( ( pitem[ i ].revents & ZMQ_POLLIN ) != 0 )
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
                        if( ( pitem[ i ].revents & ZMQ_POLLERR ) != 0 || pConn.needsClose )
                            keep = false;
                        else
                        {
                            //read checking
                            if( ( pitem[ i ].revents & ZMQ_POLLIN ) != 0 )
                                keep = onRead( pConn );

                            //write checking
                            if( ( pitem[ i ].revents & ZMQ_POLLOUT ) != 0 )
                                keep = onWrite( pConn );
                        }
                    }
                }
                catch( HttpException he )
                {
                    //an HttpException is thrown internally to indicate some HTTP protocol
                    //constraint has been broken - so we set the response status, and close the connection
                    if( pConn !is null )
                        pConn.add( he.getResponse() );
                }
                catch( Exception e )
                {
                    debug proc.onLog( "Exception occurred on fd " ~ to!string( pitem[ i ].fd ) ~
                                      ":" ~ e.toString() );
                    keep = false;
                    incStat( "num_errors" );
                    debug showStats();
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

            pitem = ptmp; //swap poll lists
            setStat( "num_connections", pitem.length - 1 ); // -1 as that's the listen socket
        }

        //do idle processing
        receivedData = proc.onIdle();
        setStat( "received_data_flag", receivedData ? 1 : 0 );
    }

    proc.onExit();
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

    void onRequest( shared( Request ) req )
    {
        req.tid = cast(shared) thisTid();
        send( tid, req );
    }

    bool onIdle()
    {
        bool found = false;

        receiveTimeout( dur!"usecs"( 0 ),
        ( int i )
        {
            running = ( i != 1 );
        },
        ( HttpResponse resp )
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

    this( HttpResponse delegate(HttpRequest) d, string logPrefix = "[HTTP] " )
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

    void onRequest( HttpRequest req )
    {
        HttpResponse resp = dg( req );

        hadData = false;
        if( resp !is null )
        {
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

protected:

    HttpResponse delegate(HttpRequest) dg;
    string prefix;
    bool   hadData;
}

// ------------------------------------------------------------------------- //

class ZmqProcessor : HttpProcessor
{
public:

    this( string ipcAddr, string logPrefix = "[ZMQ] " )
    {
        prefix = logPrefix;
        sock = new ZSocket( ipcAddr, ZMQ_PUSH );
    }

    void onInit()
    {
        onLog( "Protocol initialising (ZMQ mode)" );
    }

    void onLog( string s )
    {
        writeln( prefix ~ s );
    }

    void onExit()
    {
        onLog( "Protocol exiting (ZMQ mode)" );
    }

    void onRequest( HttpRequest req )
    {
        //1. Serialise request
        //2. Send request over ZMQ socket
        
    }

    bool onIdle()
    {
        //1. Attempt to receive request
        hadData = false;
        return hadData;
    }

protected:

    ZSocket sock;
    string prefix;
    bool   hadData;
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

int findEndOfHeaders( ubyte[] buf )
{
    auto res = findSplit( buf, NEWLINE ~ NEWLINE );
    if( !res[ 1 ].empty ) //found
        return cast(int) res[ 0 ].length + 4;

    return -1;
}

// ------------------------------------------------------------------------- //

Tuple!( HttpRequest, ulong ) parseHttpHeaders( ubyte[] buf )
{
    HttpRequest req = new HttpRequest;
    ulong reqLen = 0UL;

    auto res = findSplit( buf, NEWLINE );
    //first line should be OP URL PROTO
    auto line  = splitter( res[ 0 ], ' ' );

    req.method = toMethod( (cast(char[]) line.front ).idup );
    line.popFront;
    req.uri    = ( cast(char[]) line.front ).idup;
    line.popFront;
    req.protocol = (cast(char[]) joiner( line, cast(ubyte[])[' '] ).array()).idup;

    auto tmp = std.algorithm.splitter( cast(string) req.uri, "?" );
    if( !tmp.empty )
    {
        req.uri = tmp.front;
        tmp.popFront;

        if( !tmp.empty )
            req.attrs[ "Query-String" ] = tmp.front;
    }

    bool foundEndHeader = false;
    for( res = findSplit( res[ 2 ], NEWLINE ); res[ 0 ].length > 0; )
    {
        auto hdr = findSplit( res[ 0 ], ": " );
        if( hdr.length > 0 )
        {
            string key = capHeaderInPlace( ( cast( char[] ) hdr[ 0 ] ) ).idup;
            string val = ( cast( char[] ) hdr[ 2 ] ).idup;

            req.headers[ key ] ~= val;
            if( key == "Content-Length" )
                reqLen = to!ulong( val );
        }

        res = findSplit( res[ 2 ], NEWLINE );
        foundEndHeader = (res[ 0 ].length == 0);
    }

    if( !foundEndHeader )
    {
        debug dumpHex( cast(char[]) buf, "Failed to locate end-of-headers in input buffer" );
        incStat( "num_missed_header_termination" );
        return tuple( cast(HttpRequest) null, 0UL );
    }

    if( reqLen > MAX_REQUEST_LEN )
    {
        incStat( "num_max_length_exceeded" );
        throw new Exception( format( "Maximum request length exceeded (%d > %d) - aborting", reqLen, MAX_REQUEST_LEN ) );
    }

    if( reqLen > DIVERT_REQUEST_LEN )
    {
        incStat( "num_divert_length_exceeded" );
        version(Posix)
        {
            req.path = "/tmp/httpd.XXXXXX".idup;
            mkstemp( (cast(char[]) req.path).ptr );
        }
        else
        {
            assert( 0, "Temp file not yet implemented" );
        }
        debug writefln( "Request length is greater than diversion length (%d > %d) - writing data to file %s", reqLen, DIVERT_REQUEST_LEN, to!string( cast(char[]) req.data ) );
        onHttpData( req, res[ 2 ] );
    }
    else
        req.data = cast( shared ubyte[] ) res[ 2 ];

//    debug dumpHex( cast( char[] ) req.data, "HTTP REQUEST" );
    return tuple( req, reqLen );
}

// ------------------------------------------------------------------------- //

unittest
{
    string httpHeader = "
GET /api/abc HTTP/1.1\r
Host: localhost:8888\r
Connection: keep-alive\r
Cache-Control: max-age=0\r
User-Agent: Mozilla/5.0 (X11; Linux x86_64) Apple WebKit/537.1 (KHTML,like Gecko) Chrome/21.0.118 0.89 Safari/537.1\r
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r
Accept-Encoding: gzip,deflate,sdch\r
Accept-Language: en-US,en;q=0.8\r
Accept-Charset: UTF-8,*;q=0.5\r
Cookie: smplrefresh=5; speedlog2=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0; session_id=ece22920c6820896881a4aab7080b299532433c5\r
";
    StopWatch sw;
    sw.start();
    for( int i = 0; i < 1_000; ++i )
    { 
        auto res = parseHttpHeaders( cast(ubyte[]) httpHeader.dup );
        assert( res[ 0 ] !is null );
        assert( res[ 1 ] == 0 );
    }
    writefln( "Executed 1,000 headers parses in %dus", sw.peek().usecs / 1_000 ); 
}

// ------------------------------------------------------------------------- //

ulong onHttpData( HttpRequest req, ubyte[] buf )
{
    if( req is null || buf.length <= 0 )
        return 0UL;

    ulong len = 0UL;
    if( req.path !is null )
    {
//            debug writefln( "Appending %d bytes to file %s", buf.length, to!string(cast(char[]) req.path ) );
        auto f = File( to!string( cast(char[]) req.path ), "a" );
        f.write( cast(char[]) buf );
        f.flush();
        len = f.tell();
    }
    else
    {
        req.data ~= buf;
        len = req.data.length;
    }

    if( auto val = "Content-Length" in req.headers )
        return to!ulong( cast(string) *val ) - len;

    return len;
}

// ------------------------------------------------------------------------- //

Tuple!( ubyte[], bool ) toBuffer( HttpResponse r, bool isChunked = false )
{
    auto buf = appender!( ubyte[] )();
    buf.reserve( 512 );

    bool needsClose = false;

    if( !isChunked )
    {
        buf.put( cast( ubyte[] ) HTTP_11 );
        buf.put( ' ' );

        buf.put( cast( ubyte[] ) to!string( r.statusCode ) );
        buf.put( ' ' );
        buf.put( cast( ubyte[] ) r.statusMesg );
        buf.put( '\r' );
        buf.put( '\n' );

        r.addHeader( SERVER_HEADER, SERVER_DESC );

        if( !( "Date" in r.headers ) )
        {
            long now = time( null );
            r.addHeader( "Date", to!string( asctime( gmtime( & now ) ) )[0..$ -1] );
        }

        if( "Connection" in r.headers )
        {
            needsClose = r.headers[ "Connection" ][ 0 ] == "close";

            if( !needsClose && r.protocol.toUpper == HTTP_11 )
                r.addHeader( "Connection", "Keep-Alive" );
        }

        if( !( "Content-Length" in r.headers ) )
        r.addHeader( "Content-Length", to!string( r.data.length ) );

        foreach( k, v1; r.headers )
        {
            foreach( v; v1 )
            {
                buf.put( cast( ubyte[] ) k );
                buf.put( ':' );
                buf.put( ' ' );
                buf.put( cast( ubyte[] ) v );
                buf.put( '\r' );
                buf.put( '\n' );
            }
        }
    }
    else
    {
        //we are in "chunked" Transfer-Encoding mode, so we hexiy the length
        buf.put( cast(ubyte[]) format( "%x\r\n", r.data.length ) );
    }

    buf.put( '\r' );
    buf.put( '\n' );

    if( r.data.length > 0 )
        buf.put( cast( ubyte[] ) r.data );

//    debug dumpHex( cast( char[] ) buf.data, "HTTP RESPONSE" );
    return tuple( buf.data, needsClose );
}

// ------------------------------------------------------------------------- //

ubyte[] toBuffer( HttpRequest req )
{
    ubyte[] buf;

    buf ~= format( "%s %s %s\r\n", to!string( req.method ), req.uri.dup, req.protocol.dup );
    buf ~= format( "Host: %s\r\n", req.getHeader( "Host" ) );
    foreach( k,v1; req.headers )
    {
        if( k != "Host" )
        {
            foreach( v; v1 )
                buf ~= format( "%s: %s\r\n", k.dup, v.dup );
        }
    }

    buf ~= format( "Connection: %s\r\n\r\n", req.protocol == HTTP_10 ? "close" : "Keep-Alive" );
    return buf;
}

// ------------------------------------------------------------------------- //

bool isChunked( T )( T r )
{
    return "Transfer-Encoding" in r.headers &&
           r.headers[ "Transfer-Encoding" ][ 0 ].toLower == "chunked";
}

// ------------------------------------------------------------------------- //

ulong hexToULong( ubyte[] d )
{
    ulong val = 0;
    int pow = 1;
    foreach( u; std.range.retro( d ) )
    {
        val += ( isDigit( u ) ? u - '0' : u - ( 'A' - 10 ) ) * pow;
        pow *= 16;
    }
    return val;
}

unittest
{
    assert( hexToULong( ['3', '1', 'C'] ) == 796 );
}

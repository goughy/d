module protocol.ajp;

public import protocol.http;

import std.stdio, std.string, std.conv, std.stdint, std.array,
       std.file, std.datetime, std.socket, std.concurrency, std.typecons;

enum TIMEOUT_USEC = 500;
enum MAX_REQLEN   = 1024 * 1024 * 1; //1MB

bool running = false;

// ------------------------------------------------------------------------- //

enum PacketType //: int
{
    FORWARD      = 2,
    SEND_CHUNK   = 3,
    SEND_HEADERS = 4,
    END_RESPONSE = 5,
    GET_CHUNK    = 6,
    SHUTDOWN     = 7,
    PING         = 8,
    C_PONG       = 9,
    C_PING       = 10,
}

enum AjpMethod
{
    OPTIONS          = 1,
    GET              = 2,
    HEAD             = 3,
    POST             = 4,
    PUT              = 5,
    DELETE           = 6,
    TRACE            = 7,
    PROPFIND         = 8,
    PROPPATCH        = 9,
    MKCOL            = 10,
    COPY             = 11,
    MOVE             = 12,
    LOCK             = 13,
    UNLOCK           = 14,
    ACL              = 15,
    REPORT           = 16,
    VERSION_CONTROL  = 17,
    CHECKIN          = 18,
    CHECKOUT         = 19,
    UNCHECKOUT       = 20,
    SEARCH           = 21,
    MKWORKSPACE      = 22,
    UPDATE           = 23,
    LABEL            = 24,
    MERGE            = 25,
    BASELINE_CONTROL = 26,
    MKACTIVITY       = 27,
}

string[] ReqHeaders = [ "", //dummy entry
                        "accept",
                        "accept-charset",
                        "accept-encoding",
                        "accept-language",
                        "authorization",
                        "connection",
                        "content-type",
                        "content-length",
                        "cookie",
                        "cookie2",
                        "host",
                        "pragma",
                        "referer",
                        "user-agent" ];

string[] Attributes = [  "", //dummy entry
                         "context",
                         "servlet_path",
                         "remote_user",
                         "auth_type",
                         "query_string",
                         "route",
                         "ssl_cert",
                         "ssl_cipher",
                         "ssl_session",
                         "req_attribute",
                         "ssl_key_size",
                         "secret",
                         "stored_method",
                         "are_done" ];

string[] RespHeaders = [ "",
                         "content-type",
                         "content-language",
                         "content-length",
                         "date",
                         "last-modified",
                         "location",
                         "set-cookie",
                         "set-cookie2",
                         "servlet-engine",
                         "status",
                         "www-authenticate" ];

// ------------------------------------------------------------------------- //
// ------------------------------------------------------------------------- //

char[] getString( ubyte[] buf, ref int pos )
{
    int slen = getInt( buf, pos );

    if( slen == -1 || slen == 0xFFFF )
        return [];

//    debug writefln( "Read string at pos %d, len %d", pos, slen );
    int cpos = pos;
    pos += slen + 1;         // +1 skips \0 at end of string

    return cast( char[] ) buf[ cpos .. pos - 1 ];
}

int getInt( ubyte[] buf, ref int pos )
{
    return ( ( cast( uint ) buf[ pos++ ] << 8 ) & 0xFFFF ) + buf[ pos++ ];
}

void putByte( ref Appender!( ubyte[] ) builder, ubyte b )
{
    builder.put( b );
}

void putInt( ref Appender!( ubyte[] ) builder, int x )
{
    builder.put( cast( ubyte )( ( x >>> 8 ) & 0xFF ) );
    builder.put( cast( ubyte )( x & 0xFF ) );
}

void putString( ref Appender!( ubyte[] ) builder, immutable( char )[] s )
{
    putInt( builder, cast( int ) s.length );
    builder.put( cast( ubyte[] ) s );
    builder.put( '\0' );
}

void putData( ref Appender!( ubyte[] ) builder, ubyte[] a )
{
    putInt( builder, cast( int ) a.length );
    builder.put( a );
    builder.put( '\0' );
}

void putPrelude( ref Appender!( ubyte[] ) builder, PacketType t, int len = 0 )
{
    putByte( builder, 'A' );
    putByte( builder, 'B' );
    putInt( builder, len + 1 ); //placeholder for length
    putByte( builder, cast( ubyte ) t );
}

void putLength( ref Appender!( ubyte[] ) builder, int len )
{
    len += 1; //add prefix + data len + type byte
    builder.data()[ 2 ] = cast( ubyte )( ( len >>> 8 ) & 0xFF );
    builder.data()[ 3 ] = cast( ubyte )( len & 0xFF );
}

// ------------------------------------------------------------------------- //

ubyte[] readAjpMsg( Socket client )
{
    ubyte packLen[ 4 ];
    int  num = cast( int ) client.receive( packLen );

    if( num != 4 || packLen[ 0 ] != 0x12 || packLen[ 1 ] != 0x34 )
    {
        debug dumpHex( cast( char[] ) packLen, "Header" );
        throw new Exception( "AJP protocol error: received invalid packet header" );
    }

    int dataLen = ( cast( int ) packLen[ 2 ] << 8 ) + packLen[ 3 ];

    ubyte[] reqData;
    reqData.length = dataLen;
    reqData.length = cast( int ) client.receive( reqData );

    if( reqData.length == 0 )
        throw new Exception( "AJP protocol error: received 0 bytes from upstream" );

    return reqData;
}

// ------------------------------------------------------------------------- //

ubyte[] convertResponse( shared( Response ) r )
{
    //for a response, we need to send an AJP13_SEND_HEADERS
    //followed by an AJP13_SEND_BODY_CHUNK

    auto buf = appender!( ubyte[] )();
    buf.reserve( 512 );

    putPrelude( buf, PacketType.SEND_HEADERS );
    putInt( buf, r.statusCode );
    putString( buf, r.statusMesg );

    putInt( buf, cast( int ) r.headers.length );

    foreach( k, v1; r.headers )
    {
        foreach( v; v1 )
        {
            switch( k.toLower )
            {
                case "content-type":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x01 );
                    break;

                case "content-language":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x02 );
                    break;

                case "content-length":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x03 );
                    break;

                case "date":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x04 );
                    break;

                case "last-modified":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x05 );
                    break;

                case "location":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x06 );
                    break;

                case "set-cookie":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x07 );
                    break;

                case "set-cookie2":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x08 );
                    break;

                case "servlet-engine":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x09 );
                    break;

                case "status":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x0A );
                    break;

                case "www-authenticate":
                    putByte( buf, 0xA0 );
                    putByte( buf, 0x0B );
                    break;

                default:
                    putString( buf, k );
                    break;
            }

            putString( buf, v );
        }
    }

    //ensure we had a "Content-Length" header
    //if not, make one
    if( !( "Content-Length" in r.headers ) )
    {
        putByte( buf, 0xA0 );
        putByte( buf, 0x03 );
        putString( buf, to!string( r.data.length ) );
    }

    //now go back and set the length
    debug writefln( "Header packet length is %d", buf.data.length - 4 );
    putLength( buf, cast( int ) buf.data.length - 5 );
    debug dumpHex( cast( char[] ) buf.data, "HEADER PACKET" );

    if( r.data.length > 0 )
    {
        putPrelude( buf, PacketType.SEND_CHUNK, cast( int ) r.data.length + 3 ); //add the packet type
        putData( buf, cast( ubyte[] ) r.data );
    }

    debug dumpHex( cast( char[] ) buf.data[ buf.data.length - r.data.length  - 5 .. $ ], "SEND_CHUNK PACKET" );

    //add END_RESPONSE packet
    buf.put( END );

    debug dumpHex( cast( char[] ) buf.data, "AJP RESPONSE" );
    return buf.data;
}

// ------------------------------------------------------------------------- //

static ubyte[] PONG;
static ubyte[] END;

AjpConnection[string] allConns;

static this()
{
    auto buf = appender!( ubyte[] )();
    putPrelude( buf, PacketType.C_PONG, 5 );
    putInt( buf, 1 );
    putInt( buf, 0 );                //zero length string
    buf.put( cast( ubyte ) '\0' );               //null terminator
    PONG = buf.data;

    buf = appender!( ubyte[] )();
    putPrelude( buf, PacketType.END_RESPONSE, 1 );
    putByte( buf, 1 ); //reuse flag
    END = buf.data;
}

// ------------------------------------------------------------------------- //

Tuple!( shared( Request ), int ) parseAjpForward( ubyte[] buf )
{
    debug writefln( "AJP forward message size = %d", buf.length );

    if( buf is null )
        throw new Exception( "AJP Message parse failure: buffer is NULL" );

    int pos  = 1;        //skip the 'type' byte - its already set
    shared Request req = new shared( Request )();

//      type       = cast(PacketType) _buf[ pos++ ];
    req.method     = toMethod( buf[ pos++ ] );
    req.protocol   = getString( buf, pos ).idup;
    req.uri        = getString( buf, pos ).idup;

    //may receive end-of-attribute tag...
    while( buf[ pos ] == 0xff )
        pos++; //just skip them...

    debug writefln( "AJP forward message method (%s), uri: %s", to!string( req.method ), req.uri );

    req.attrs[ "remote-address" ]   = getString( buf, pos ).idup;
    req.attrs[ "remote-host" ]      = getString( buf, pos ).idup;
    req.attrs[ "server-name" ]      = getString( buf, pos ).idup;
    req.attrs[ "server-port" ]      = to!string( getInt( buf, pos ) );
    req.attrs[ "is-ssl" ]           = buf[ pos++ ] == 0 ? "false" : "true";
//    debug dump( req, "PRE HEADERS" );

    int reqLen = 0;

    //parse the headers
    for( int i = getInt( buf, pos ); i > 0; i-- )
    {
        if( buf[ pos ] == 0xA0 )   //special marker
        {
            pos++;                 //skip 0xA0
            int    idx = buf[ pos++ ];
            string key = ReqHeaders[ idx ].idup;
            string val = getString( buf, pos ).idup;

            debug writefln( "(D) header %d: %s = %s", i, key, val );

            req.headers[ key ] ~= val;

            if( idx == 0x08 )                 //ie. "Content-Length" header
            {
                reqLen = to!int( val );

                if( reqLen > MAX_REQLEN )
                    throw new Exception( "Maximum request size exceeded (" ~ val ~ " > " ~ to!string( MAX_REQLEN ) );
            }
        }
        else
        {
            string key = getString( buf, pos ).idup;
            char[] val = getString( buf, pos );

            debug writefln( "(D) header %d: %s = %s", i, key, val );

            req.headers[ key.toLower ] ~= val.idup;
        }
    }

    //now look for additional attributes (if they exist)
    while( pos < buf.length )
    {
        if( buf[ pos ] == 0x0A )
        {
            int idx = buf[ pos++ ];
            req.attrs[ getString( buf, pos ).idup ] = getString( buf, pos ).idup;
        }
        else if( buf[ pos ] == 0xFF )
        {
            pos++;                 //ignored!
            break;
        }
        else
        {
            int idx = buf[ pos++ ];
            req.attrs[ Attributes[ idx ].idup ] = getString( buf, pos ).idup;
        }
    }

    return tuple( req, reqLen );
}

// ------------------------------------------------------------------------- //

class AjpConnection
{
public:

    this( Socket _c )
    {
        _socket = _c;
        _id     = _c.remoteAddress().toString();
    }

    @property string id()     { return _id; }
    @property Socket socket() { return _socket; }

    void close()
    {
        debug writefln( "Closing connection %s (%s)", id, to!string( cast( int ) _socket.handle() ) );

        try
        {
            if( _socket.isAlive )
                _socket.shutdown( SocketShutdown.BOTH );

            _socket.close();
        }
        catch( Throwable t )
        {
            writefln( "(E) socket close failed on connection %s: %s", _id, t.toString() );
        }
    }

    shared( Request ) read()
    {
//        if( _state & Flags.CLOSING )
//            throw new Exception( "Attempted to read from CLOSED connection " ~ _id );
//
//        debug writefln( "Reading next AJP packet from connection %s", id );
//        ubyte[] buf = readAjpMsg( _socket );
//        if( (_state & Flags.READING) == 0 )
//        {
//            debug writefln( "Received AJP message of %d bytes", buf.length );
//            if( buf[ 0 ] == PacketType.FORWARD )
//            {
//                debug dumpHex( cast(char[]) buf, "AJP REQUEST" );
//
//                Tuple!(shared(Request),int) rt = parseAjpForward( cast(ubyte[]) buf );
//                _lastReq = rt[ 0 ];
//                _lastReadPos = rt[ 1 ];
//                _lastReq.connection = id;
//                if( _lastReq.data.length > 0 )
//                    _state |= Flags.READING;
//            }
//            else if( buf[ 0 ] == PacketType.C_PING )
//            {
//                debug writeln( "CPING received from server, send CPONG" );
//                _lastResp ~= PONG; //send PONG back upstream
//                _state |= Flags.WRITING;
//            }
//        }
//        else
//        {
//            _lastReq.data = cast(shared ubyte[]) buf; //append POST data (if any)
//            _state &= ~Flags.READING;
//        }
//
//        return (_state & Flags.READING) > 0 ? null : _lastReq;
        return null;
    }

    //write any pending data to the socket, and return completion flag
    //true == finished writing, false == data left...
    ulong write()
    {
//        if( _lastWritePos == _lastResp.length )
//        {
//            _state &= ~Flags.WRITING;
//            return 0UL; //nothing to send
//        }
//
//        long num = _socket.send( _lastResp[ _lastWritePos .. $ ] );
//        debug writefln( "Wrote %d bytes to connection %s", num, id );
//        if( num < 0 )
//        {
//            _state &= ~Flags.WRITING;
//            return 0UL;
//        }
//
//        _lastWritePos += num;
//        if( _lastWritePos >= _lastResp.length )
//        {
//            _lastResp.length = _lastWritePos = 0;
//            _state &= ~Flags.WRITING;
//            return 0UL;
//        }
//        _state |= Flags.WRITING;
//        return _lastResp.length - _lastWritePos;
        return 0UL;
    }

    void add( shared( Response ) r )
    {
        debug dump( r );
        _lastResp ~= convertResponse( r );
//        _state |= Flags.WRITING;
    }

private:

    string  _id;
    Socket  _socket;
    shared Request _lastReq;
    ubyte[] _lastResp;
    int     _lastWritePos;
    int     _lastReadPos;
}

// ------------------------------------------------------------------------- //

/**
 * Inline AJP processor - direct delegate call
 */
private void ajpServeImpl( string address, ushort port, HttpProcessor proc )
{
    proc.onInit();
    running = true;

    SocketSet readSet = new SocketSet();
    SocketSet writeSet = new SocketSet();
    SocketSet exceptSet = new SocketSet();

    InternetAddress bindAddr = new InternetAddress( address, port );

    //TODO: loop accepting all available connections...
    void doAccept( Socket s )
    {
        Socket client = s.accept();
        client.blocking( false );

        client.setOption( SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1 );
//        linger lin = { 1, 500 };
//        client.setOption( SocketOptionLevel.SOCKET, SocketOption.LINGER, lin );

        AjpConnection conn = new AjpConnection( client );// id is allocated in the constructor
        proc.onLog( "accepted new client connection from " ~ conn.id );
        allConns[ conn.id ] = conn;
    }

    void doRead( AjpConnection c )
    {
        try
        {
            shared Request req = c.read();

            if( req !is null )
                proc.onRequest( req );
        }
        catch( Exception e )
        {
            debug writefln( "Exception " ~ e.toString() );
            c.close();
        }
    }

    void doWrite( AjpConnection c )
    {
        debug writefln( "Write set on connection %s", c.id );
        c.write();
    }

    void doExcept( AjpConnection c )
    {
        debug writefln( "Error on connection %s", c.id );
        c.close();
    }

    //set up our listening socket...
    Socket listenSock;

    try
    {
        listenSock = new Socket( AddressFamily.INET, SocketType.STREAM );
        listenSock.bind( bindAddr );
        listenSock.listen( 3 );
        listenSock.blocking( false );
        proc.onLog( "listening on " ~ bindAddr.toString() ~ ", queue length " ~ to!string( 3 ) );
    }
    catch( SocketException se )
    {
        debug writefln( se.toString() );
        throw se;
    }

//    string[] closedConns;
//    while( running )
//    {
//        readSet.reset();
//        readSet.add( listenSock );
//        writeSet.reset();
//
//        closedConns.clear();
//        foreach( c; allConns )
//        {
//            if( c.flags & Connection.Flags.CLOSING )
//            {
//                closedConns ~= c.id;
//                continue;
//            }
//
//            readSet.add( c.socket );
//            if( c.flags & Connection.Flags.WRITING )
//                writeSet.add( c.socket );
//        }
//
//        //close connections found wanting
//        //this can't be done as part of the iteration over the connections
//        //above or below as it explodes the iterator (sorry, range) if
//        //items are removed during iteration.  There is probably a way to do so, though...
//        foreach( s; closedConns )
//        {
//            proc.onLog( "removing closed connection " ~ s );
//            allConns.remove( s );
//        }
//
//        int num = Socket.select( readSet, writeSet, exceptSet, TIMEOUT_USEC );
//        if( num > 0 )
//        {
//            debug writefln( "%d/%d: ", num, allConns.length );
//            if( readSet.isSet( listenSock ) )
//                doAccept( listenSock );
//
//            foreach( c; allConns )
//            {
//                if( readSet.isSet( c.socket ) )
//                    doRead( c );
//                if( writeSet.isSet( c.socket ) )
//                    doWrite( c );
//                if( exceptSet.isSet( c.socket ) )
//                    doExcept( c );
//            }
//        }
//
//        proc.onIdle();
//    }

    proc.onLog( "shutting down " ~ to!string( allConns.length ) ~ " connection(s)" );

    //shutdown remaining sockets...
    foreach( c; allConns )
    {
        try
        {
            c.close();
        }
        catch( Throwable t ) {} //ignored
    }

    try
    {
        listenSock.close();
    }
    catch( Throwable t )
    {
        writeln( "Failed to close listen socket: " ~ t.toString() );
    }

    proc.onExit();
}

// ------------------------------------------------------------------------- //

/**
 * Thread entry point for AJP processing
 */

void ajpServe( string bindAddr, Tid tid )
{
    auto res = parseAddr( bindAddr, SERVER_PORT );
    ajpServeImpl( res[ 0 ], res[ 1 ], new TidProcessor( tid, "[AJP-D] " ) );
}

// ------------------------------------------------------------------------- //

void ajpServe( string bindAddr, RequestDelegate dg )
{
    auto res = parseAddr( bindAddr, SERVER_PORT );
    ajpServeImpl( res[ 0 ], res[ 1 ], new DelegateProcessor( dg, "[AJP-D] " ) );
}

// ------------------------------------------------------------------------- //


//enum Method { OPTIONS, GET, HEAD, POST, PUT, DELETE, TRACE, CONNECT };

Method toMethod( ubyte m )
{
    switch( m )
    {
        case AjpMethod.OPTIONS:
            return Method.OPTIONS;

        case AjpMethod.GET:
            return Method.GET;

        case AjpMethod.HEAD:
            return Method.HEAD;

        case AjpMethod.POST:
            return Method.POST;

        case AjpMethod.PUT:
            return Method.PUT;

        case AjpMethod.DELETE:
            return Method.DELETE;

        case AjpMethod.TRACE:
            return Method.TRACE;

        case AjpMethod.PROPFIND:
        case AjpMethod.PROPPATCH:
        case AjpMethod.MKCOL:
        case AjpMethod.COPY:
        case AjpMethod.MOVE:
        case AjpMethod.LOCK:
        case AjpMethod.UNLOCK:
        case AjpMethod.ACL:
        case AjpMethod.REPORT:
        case AjpMethod.VERSION_CONTROL:
        case AjpMethod.CHECKIN:
        case AjpMethod.CHECKOUT:
        case AjpMethod.UNCHECKOUT:
        case AjpMethod.SEARCH:
        case AjpMethod.MKWORKSPACE:
        case AjpMethod.UPDATE:
        case AjpMethod.LABEL:
        case AjpMethod.MERGE:
        case AjpMethod.BASELINE_CONTROL:
        case AjpMethod.MKACTIVITY:
        default:
            break;
    }

    return Method.UNKNOWN;
}

// ------------------------------------------------------------------------- //


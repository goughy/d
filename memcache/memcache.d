
import std.socket, std.stdio, std.array;
import std.conv, std.string;
import std.ascii : isPrintable;
import std.array : replicate;
private import core.sys.posix.arpa.inet;

immutable enum Magic : ubyte
{ 
    REQUEST  = 0x80, 
    RESPONSE = 0x81 
};

immutable enum Status : ushort
{
    OK              = 0x0000,
    KEY_NOTFOUND    = 0x0001,
    KEY_EXISTS      = 0x0002,
    VALUE_TOOLARGE  = 0x0003,
    INVALID_ARGS    = 0x0004,
    ITEM_NOT_STORED = 0x0006,
    NOT_NUMERIC     = 0x0006,
    UNKNOWN_COMMAND = 0x0081,
    OUT_OF_MEMORY   = 0x0082
};

immutable enum Command : ubyte
{
    GET      = 0x00,
    SET      = 0x01,
    ADD      = 0x02,
    REPLACE  = 0x03,
    DELETE   = 0x04,
    INCR     = 0x05,
    DECR     = 0x06,
    QUIT     = 0x07,
    FLUSH    = 0x08,
    GETQ     = 0x09,
    NOOP     = 0x0A,
    VERSION  = 0x0B,
    GETK     = 0x0C,
    GETKQ    = 0x0D,
    APPEND   = 0x0E,
    PREPEND  = 0x0F,
    STAT     = 0x10,
    SETQ     = 0x11,
    ADDQ     = 0x12,
    REPLACEQ = 0x13,
    DELETEQ  = 0x14,
    INCRQ    = 0x15,
    DECRQ    = 0x16,
    QUITQ    = 0x17,
    FLUSHQ   = 0x18,
    APPENDQ  = 0x19,
    PREPENDQ = 0x1A
};

immutable enum DataType : ubyte
{
    RAW = 0x00
};

immutable uint HEADER_LEN = 24;

// ------------------------------------------------------------------------- //

struct MemcacheObject
{
    Status  status;
    uint    flags;
    uint    expiry;
    ulong   cas;
    ubyte[] key;
    ubyte[] value;
}

// ------------------------------------------------------------------------- //

ulong ntohull( ulong u )
{
    uint th = cast(uint) ((u >> 32) & 0x00000000FFFFFFFF);
    uint tl = cast(uint) (u & 0x00000000FFFFFFFF);
//    writeln( "ntohull() th = ", ntohl( th ), ", tl = ", ntohl( tl ) );
    return ((cast(ulong) ntohl(tl)) << 32) | ntohl( th );
}

// ------------------------------------------------------------------------- //

ulong htonull( ulong u )
{
    uint th = cast(uint) ((u >> 32) & 0x00000000FFFFFFFF);
    uint tl = cast(uint) (u & 0x00000000FFFFFFFF);
//    writeln( "htonull() th = ", htonl( th ), ", tl = ", htonl( tl ) );
    return ((cast(ulong) htonl(tl)) << 32) | htonl( th );
}

// ------------------------------------------------------------------------- //

struct MemcacheHeader
{
    @property ubyte magic()          { return _header[ 0 ]; }
    @property ubyte magic( ubyte u ) { return _header[ 0 ] = u;    }

    @property ubyte opcode()          { return _header[ 1 ]; }
    @property ubyte opcode( ubyte u ) { return _header[ 1 ] = u;    }

    @property ushort keyLen()           { return ntohs( *(cast(ushort*) &_header[ 2 ]) ); }
    @property ushort keyLen( ushort u ) 
    { 
        *(cast(ushort*) &_header[ 2 ]) = htons( u ); 
        updateBodyLen(); 
        return u;
    }

    @property ubyte extraLen()          { return _header[ 4 ]; }
    @property ubyte extraLen( ubyte u ) 
    { 
        _header[ 4 ] = u;
        updateBodyLen(); 
        return u;
    }

    @property ubyte dataType()          { return _header[ 5 ]; }
    @property ubyte dataType( ubyte u ) { return _header[ 5 ] = u;    }

    @property Status status()           { return cast(Status) ntohs( *(cast(ushort*) &_header[ 6 ]) ); }
    @property Status status( ushort u ) { *(cast(ushort*) &_header[ 6 ]) = htons( u ); return cast(Status) u; }

    @property uint bodyLen()            { return ntohl( *(cast(uint*) &_header[ 8 ]) ); }
    @property uint valueLen( uint u )   { updateBodyLen( u ); return u; }

    @property uint opaque()             { return ntohl( *(cast(uint*) &_header[ 12 ]) ); }
    @property uint opaque( uint u )     { return *(cast(uint*) &_header[ 12 ]) = htonl( u );    }

    @property ulong cas()               { return ntohull( *(cast(ulong*) &_header[ 16 ]) ); }
    @property ulong cas( ulong u )      { *(cast(ulong*) &_header[ 16 ]) = htonull( u ); return u; }

    ubyte[ 24 ] _header;

private:

    uint _lastLen;

    void updateBodyLen()
    {
        if( _lastLen > 0 )
            updateBodyLen( _lastLen - this.extraLen - this.keyLen );
        else
            updateBodyLen( _lastLen );
    }

    void updateBodyLen( uint valueLen )
    {
        _lastLen = valueLen;
//        writeln( "bodyLen updating v = ", valueLen, ", e = ", extraLen, ", k = ", keyLen );
        *(cast(uint*) &_header[ 8 ]) = htonl( valueLen + this.extraLen + this.keyLen ); 
    }
};

// ------------------------------------------------------------------------- //

class MemcacheServer
{
public:

    this( string h = "localhost", ushort p = 11211 )
    {
       host = h;
       port = p;
    }

    bool connect()
    {
        InternetAddress addr = new InternetAddress( host, port );
        sock = new TcpSocket( addr );
        return true; //its true or an exception...
    }

    string versionStr()
    {
        if( sock is null )
            connect();

        MemcacheHeader header;
        header.magic    = Magic.REQUEST;
        header.opcode   = Command.VERSION; //command

        debug dumpHex( cast(char[]) header._header, "<< C:" );
        if( sock.send( cast(ubyte[]) header._header ) < 0 )
            throw new MemcacheException( "Failed to send header" );

        long num = sock.receive( header._header );
        debug dumpHex( cast(char[]) header._header, ">> S:" );

        //verify packet && get status
        assert( header.magic == Magic.RESPONSE );
        assert( header.opcode == Command.VERSION );

        MemcacheObject obj;
        obj.key.length  = header.keyLen;
        obj.status      = header.status;
        obj.cas         = header.cas;

        obj.value.length = header.bodyLen;
//        writeln( "Receiving an extra ", header.bodyLen, " bytes" );
        num = sock.receive( obj.value );
        debug dumpHex( cast(char[]) obj.value, ">> S:" );

        return (cast(char[]) obj.value).idup;
    }

    MemcacheObject[] get( ubyte[] key )
    {
        if( sock is null )
            connect();

        MemcacheHeader header;
        header.magic    = Magic.REQUEST;
        header.opcode   = Command.GET; //command
        header.keyLen   = cast(ushort) key.length; //key length
        header.dataType = DataType.RAW;

        debug dumpHex( cast(char[]) header._header, "<< C:" );
        if( sock.send( cast(ubyte[]) header._header ) < 0 )
            throw new MemcacheException( "Failed to send header" );

        debug dumpHex( cast(char[]) key, "<< C:" );
        if( sock.send( key ) < 0 )
            throw new MemcacheException( "Failed to send key" );

        return receiveAll();
    }

    MemcacheObject add( ref MemcacheObject obj )
    {
        if( sock is null )
            connect();

        return setImpl( Command.ADD, obj );
    }

    MemcacheObject replace( ref MemcacheObject obj )
    {
        if( sock is null )
            connect();

        return setImpl( Command.REPLACE, obj );
    }

    MemcacheObject set( ref MemcacheObject obj )
    {
        if( sock is null )
            connect();

        return setImpl( Command.SET, obj );
    }

    Status remove( ubyte[] key )
    {
        if( sock is null )
            connect();

        MemcacheHeader header;
        header.magic = Magic.REQUEST; //magic
        header.opcode = Command.DELETE; //command
        header.keyLen = cast(ushort) key.length; //key length
        header.dataType = DataType.RAW;

        debug dumpHex( cast(char[]) header._header, "<< C:" );
        if( sock.send( header._header ) < 0 )
            throw new MemcacheException( "Failed to send header" );

        debug dumpHex( cast(char[]) key, "<< C:" );
        if( sock.send( key ) < 0 )
            throw new MemcacheException( "Failed to send data" );

        long num = sock.receive( header._header );
        debug dumpHex( cast(char[]) header._header, ">> S:" );

        //verify packet && get status
        assert( header.magic == Magic.RESPONSE );
        assert( header.opcode == Command.DELETE );

        return header.status;
    }

    ulong incr( ubyte[] counter, ulong howMuch, ulong initVal = 0UL, uint expiry = 0xffffffff )
    {
        if( sock is null )
            connect();

        return incrDecr( Command.INCR, counter, howMuch, initVal, expiry );
    }

    ulong decr( ubyte[] counter, ulong howMuch, ulong initVal = 0UL, uint expiry = 0xffffffff )
    {
        if( sock is null )
            connect();

        return incrDecr( Command.DECR, counter, howMuch, initVal, expiry );
    }

    MemcacheObject[] noop()
    {
        MemcacheHeader header;
        header.magic = Magic.REQUEST; //magic
        header.opcode = Command.NOOP; //command
        header.dataType = DataType.RAW;

        debug dumpHex( cast(char[]) header._header, "<< C:NOOP REQUEST" );
        if( sock.send( header._header ) < 0 )
            throw new MemcacheException( "Failed to send header" );

        //receive the NOOP response and any pending messages
        MemcacheObject[] allObjs = receiveAll();
        assert( allObjs.length > 0 );
        MemcacheObject noopResp = allObjs[ 0 ];
        assert( noopResp.status == Status.OK );

        return allObjs[ 1 .. $ ];
    }

    string[string] stats()
    {
        string[string] arrStat;

        MemcacheHeader header;
        header.magic = Magic.REQUEST; //magic
        header.opcode = Command.STAT; //command
        header.dataType = DataType.RAW;

        debug dumpHex( cast(char[]) header._header, "<< C:STAT REQUEST" );
        if( sock.send( header._header ) < 0 )
            throw new MemcacheException( "Failed to send header" );

        while( true )
        {
            long num = sock.receive( header._header );
            if( num < 0 || header.keyLen == 0 )
                break;

            ubyte[] buf;
            buf.length = header.bodyLen;
            num = sock.receive( buf );
            arrStat[ (cast(char[]) buf[ 0 .. header.keyLen ]).idup ] = (cast(char[]) buf[ header.keyLen .. $ ]).idup; 
        }

        return arrStat;
    }

    void quit()
    {
        MemcacheHeader header;
        header.magic = Magic.REQUEST; //magic
        header.opcode = Command.QUIT; //command
        header.dataType = DataType.RAW;

        debug dumpHex( cast(char[]) header._header, "<< C:QUIT REQUEST" );
        if( sock.send( header._header ) < 0 )
            throw new MemcacheException( "Failed to send header" );

        long num = sock.receive( header._header );
        debug dumpHex( cast(char[]) header._header, "<< C:QUIT RESPONSE" );
        assert( header.status == Status.OK );

        sock.close();
        sock = null;
    }

private:

    string host;
    ushort port;
    Socket sock;
    uint   queued;

    MemcacheObject[] receiveAll()
    {
        MemcacheObject[] objs;
        objs.length = queued + 1;
        for( int i = 0; i < objs.length; ++i )
        {
            MemcacheHeader header;
            long num = sock.receive( header._header );
            debug dumpHex( cast(char[]) header._header, ">> S:" );

            MemcacheObject obj;
            obj.key.length   = header.keyLen;
            obj.status       = header.status;
            obj.cas          = header.cas;
            obj.value.length = header.bodyLen;
            if( header.bodyLen > 0 )
            {
                num = sock.receive( obj.value );
                debug dumpHex( cast(char[]) obj.value, ">> S:" );

                if( header.status == Status.OK )
                {
                    obj.flags = ntohl( *(cast(uint*) &obj.value[ 0 ]) );
                    if( header.keyLen > 0 )
                        obj.key = obj.value[ 4 .. header.keyLen + 4 ];

                    obj.value = obj.value[ header.keyLen + 4 .. $ ];
                }
            }

            objs[ i ] = obj;
        }
//        writeln( "receiveAll() returning ", objs.length, " memcache objects" );
        return objs;
    }

    MemcacheObject setImpl( Command cmd, ref MemcacheObject obj )
    {
        MemcacheHeader header;
        header.magic = Magic.REQUEST; //magic
        header.opcode = cmd; //command
        header.keyLen = cast(ushort) obj.key.length; //key length
        header.extraLen = 0x08; //extra length
        header.dataType = DataType.RAW;
        header.valueLen  = cast(uint) obj.value.length;

        //extras
        auto sendBuf = appender!(ubyte[])();
        sendBuf.reserve( obj.key.length + obj.value.length + 8 );
        for( int i = 0; i < uint.sizeof; ++i )
            sendBuf.put( cast(ubyte) (htonl(obj.flags) >> 8*i & 0xFF) );
        for( int i = 0; i < uint.sizeof; ++i )
            sendBuf.put( cast(ubyte) (htonl(obj.expiry) >> 8*i & 0xFF) );

        sendBuf.put( obj.key );
        sendBuf.put( obj.value );

        debug dumpHex( cast(char[]) header._header, "<< C:" );
        if( sock.send( header._header ) < 0 )
            throw new MemcacheException( "Failed to send header" );

        debug dumpHex( cast(char[]) sendBuf.data, "<< C:" );
        if( sock.send( sendBuf.data ) < 0 )
            throw new MemcacheException( "Failed to send data" );

        long num = sock.receive( header._header );
        debug dumpHex( cast(char[]) header._header, ">> S:" );

        //verify packet && get status
        assert( header.magic == Magic.RESPONSE );
        assert( header.opcode == cmd );

        obj.status = header.status;
        obj.cas    = header.cas;
        return obj;
    }

    ulong incrDecr( Command cmd, ubyte[] counter, ulong howMuch, ulong initVal, uint expiry )
    {
        MemcacheHeader header;
        header.magic = Magic.REQUEST; //magic
        header.opcode = cmd; //command
        header.keyLen = cast(ushort) counter.length; //key length
        header.dataType = DataType.RAW;
        header.extraLen = 20;
 
        debug dumpHex( cast(char[]) header._header, "<< C:INCR/DECR REQUEST" );
        if( sock.send( header._header ) < 0 )
            throw new MemcacheException( "Failed to send header" );
       //extras
        ubyte buf[];
        buf.length = 20 + header.keyLen;
        *(cast(ulong*) &buf[ 0 ]) = htonull( howMuch );
        *(cast(ulong*) &buf[ 8 ]) = htonull( initVal );
        *(cast(uint*)  &buf[ 16 ]) = htonl( expiry );
        buf[ 20 .. $ ] = counter;

        debug dumpHex( cast(char[]) buf, "<< C:INCR/DECR BODY" );
        if( sock.send( buf ) < 0 )
            throw new MemcacheException( "Failed to send data" );

        long num = sock.receive( header._header );
        debug dumpHex( cast(char[]) header._header, ">> S:INCR/DECR RESPONSE" );

        //verify packet && get status
        assert( header.magic == Magic.RESPONSE );
        assert( header.opcode == cmd );

        buf.length = header.bodyLen;
        if( buf.length > 0 )
        {
            num = sock.receive( buf );
            debug dumpHex( cast(char[]) buf, ">> S: INCR/DECR BODY" );
            if( header.status == Status.KEY_NOTFOUND && expiry == 0xffffffff )
                throw new MemcacheException( header.status, (cast(char[]) buf).idup );
            
            if( header.status == Status.OK )
                return ntohull( *(cast(ulong*) &buf[ 0 ] ));
        }
        return initVal;
    }

}

// ------------------------------------------------------------------------- //

class MemcacheException : Exception
{
    this( string msg )
    {
        super( msg );
    }

    this( Status s, string msg )
    {
        super( to!string( s ) ~ " - " ~ msg );
    }

    @property Status status() { return status; }

private:

    Status stat;
}

// ------------------------------------------------------------------------- //
//struct MemcacheObject
//{
//    Status  status;
//    uint    flags;
//    uint    expiry;
//    ulong   cas;
//    ubyte[] key;
//    ubyte[] value;
//}

void dump( MemcacheObject o )
{
    writeln( "O: status " ~ to!string( o.status ) );
    writefln( "O: flags  %08x", o.flags );
    writeln( "O: expiry " ~ to!string( o.expiry ) );
    writeln( "O: cas    " ~ to!string( o.cas ) );
    dumpHex( cast(char[]) o.key, "O: key" );
    dumpHex( cast(char[]) o.value, "O: value" );
}

void dumpHex( char[] buf, string title = "", int cols = 16 )
{
    assert( cols < 256 );

    if( title.length > 0 )
        writeln( title );

    char[ 256 ] b1;
    int x = 0, i = 0;
    for(; i < buf.length; ++i )
    {
        if( x > 0 && i > 0 && i % cols == 0 )
        {
            writefln( "   %s", b1[ 0 .. x ] );
            x = 0;
        }
        b1[ x++ ] = .isPrintable( buf[ i ] ) ? buf[ i ] : '.';
        writef( "%02x ", buf[ i ] );
    }
//		writefln( "\n(D) x = %d, i = %d", x, i );
    if( x > 0 )
        writefln( "%s   %s", ( cols > x ) ? replicate( "   ", cols - x ) : "", b1[ 0 .. x ] );
}



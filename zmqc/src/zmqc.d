
module zmqc;

import std.stdio, std.string, std.conv, std.getopt, std.range, std.c.stdlib, std.datetime, core.thread : Thread;
import zmq;

string zmqIdentity;
bool running = true;

// ------------------------------------------------------------------------- //

class ZMsg
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

class ZSocket
{
    static void * zmqCtx;
    static string zmqIdent;

    static this()
    {
        zmqCtx = zmq_init( 1 );
    }

    static ~this()
    {
        zmq_term( zmqCtx );
    }

    static string verStr()
    {
        int major, minor, patch;
        zmq_version( &major, &minor, &patch );
        return format( "%d.%d.%d", major, minor, patch );
    }

    void * zmqSock;
    ZMsg zmqMsg;

    this( int type )
    {
        zmqSock = zmq_socket( zmqCtx, type );
//        zmq_connect( zmqSock, addr.toStringz );
    }

    ~this()
    {
        close();
    }

    void bind( string addr )
    {
        debug writefln( "BIND: %s", addr );
        zmq_bind( zmqSock, addr.toStringz );
    }

    void connect( string addr )
    {
        debug writefln( "CONNECT: %s", addr );
        zmq_connect( zmqSock, addr.toStringz );
    }

    ZMsg receive( int flags = 0 )
    {
        if( zmqMsg is null )
            zmqMsg = new ZMsg();

        if( zmq_recv( zmqSock, cast( zmq_msg_t* ) zmqMsg, flags ) == 0 )
        {
            ZMsg msg = zmqMsg;
            zmqMsg = null;
            return msg;
        }
        return null;
    }

    void send( ZMsg msg )
    {
        zmq_send( zmqSock, cast( zmq_msg_t * ) msg, 0 ); //send it off
        msg.destroy();
    }

    void send( char[] buf )
    {
        send( new ZMsg( buf ) );
    }

    int setSockOpt( int optName, char[] val )
    {
        debug writefln( "SOCKOPT: %d - %s", optName, val );
        return zmq_setsockopt( zmqSock, optName, cast(void *) val.ptr, val.length );
    }

    int setSockOpt( int optName, void * val, size_t vlen )
    {
        debug writefln( "SOCKOPT: %d - %s", optName, val );
        return zmq_setsockopt( zmqSock, optName, val, vlen );
    }

    void close()
    {
        if( zmqSock !is null )
            zmq_close( zmqSock );
    }

    void * opCast( T : void * )()
    {
        return zmqSock;
    }
}

// ------------------------------------------------------------------------- //

enum SockType { PUSH = ZMQ_PUSH, 
                PULL = ZMQ_PULL, 
                PUB  = ZMQ_PUB, 
                SUB  = ZMQ_SUB, 
                REQ  = ZMQ_REQ, 
                REP  = ZMQ_REP, 
                PAIR = ZMQ_PAIR };

// ------------------------------------------------------------------------- //

int main( string[] args )
{
    bool nullDelim = false;
    int num = -1;
    bool readMode = false;
    bool writeMode = false;
    bool doBind = false;
    bool doConnect = false;
    string[] options;

    getopt( args,
            "0", &nullDelim, 
            "n|num", &num,
            "r|read", &readMode,
            "w|write", &writeMode,
            "b|bind", &doBind,
            "c|connect", &doConnect,
            "o|options", &options );

    string type;
    string[] addr;
    if( args.length > 1 )
        type = args[ 1 ];
    if( args.length > 2 )
        addr = args[ 2 .. $ ];

    dchar delim = nullDelim ? '\0' : '\n';

    SockType st = to!SockType( type );
    debug writefln( "zmq version = %s, type = %s, address = %s ", ZSocket.verStr, type, addr );

    if( st == SockType.SUB && writeMode )
        throw new Exception( "Cannot write to a SUB socket" );
    else if( st == SockType.PUB && readMode )
        throw new Exception( "Cannot read from a PUB socket" );
    else if( (readMode || writeMode) && (st == SockType.REQ || st == SockType.REP) )
        throw new Exception( "Cannot choose a read/write mode with a " ~ type ~ " socket" );
    else if( (!readMode && !writeMode) && (st != SockType.REQ && st != SockType.REP) )
        throw new Exception( "Either read (-r/--read) or write (-w/--write) is required for a " ~ type ~ " socket" );

    if( !doBind && !doConnect )
        throw new Exception( "One of bind (-b/--bind) or connect (-c/--connect) is required" );

    ZSocket conn = new ZSocket( st );
    foreach( a; addr )
    {
        if( doBind )
            conn.bind( a );
        else if( doConnect )
            conn.connect( a );
    }

    int linger = 2000;
    conn.setSockOpt( ZMQ_LINGER, cast(void *) & linger, linger.sizeof );

    if( st == SockType.SUB )
        conn.setSockOpt( ZMQ_SUBSCRIBE, "".dup );

    char[] buf;
    foreach( n; take( recurrence!("a[n-1]+1")(1), num ) )
    {
//        debug writefln( "Iteration %d", n );

        if( st == SockType.REQ )
        {
            if( stdin.readln( buf, delim ) <= 0 )
                break;

            conn.send( buf );
            write( conn.receive().data() );
        }
        else if( st == SockType.REP )
        {
            write( conn.receive().data() );

            if( stdin.readln( buf, delim ) <= 0 )
                break;

            conn.send( buf );
        }
        else if( readMode )
            write( "RECEIVE: ", conn.receive().data() );
        else if( writeMode )
        {
            if( stdin.readln( buf, delim ) <= 0 )
                break;

            debug writef( "SEND: %s", buf );
            conn.send( buf );
        }
    }
    conn.close();
    return 0;
}



module zmqc;

import std.stdio, std.string, std.conv, std.getopt, std.range, std.c.stdlib, std.datetime, core.thread : Thread;
import zmq;

string zmqIdentity;
bool running = true;

// ------------------------------------------------------------------------- //

class ZSocket
{
    static void * zmqCtx;
    static string zmqIdent;

    static this()
    {
        zmqCtx = zmq_ctx_new();
    }

    static ~this()
    {
        zmq_ctx_destroy( zmqCtx );
    }

    static string verStr()
    {
        int major, minor, patch;
        zmq_version( &major, &minor, &patch );
        return format( "%d.%d.%d", major, minor, patch );
    }

    void * zmqSock;

    this( int type )
    {
        zmqSock = zmq_socket( zmqCtx, type );
    }

    ~this()
    {
        close();
    }

    void bind( string addr )
    {
        debug writefln( "BIND: %s", addr );
        assert( zmq_bind( zmqSock, addr.toStringz ) == 0 );
    }

    void connect( string addr )
    {
        debug writefln( "CONNECT: %s", addr );
        assert( zmq_connect( zmqSock, addr.toStringz ) == 0 );
    }

    char[] receive( int flags = 0 )
    {
        zmq_msg_t msg;
        assert( zmq_msg_init( &msg ) == 0 );
        auto len = zmq_msg_recv( & msg, zmqSock, flags );
        assert( len >= 0 );
        char[] data = cast(char[]) zmq_msg_data( & msg )[ 0 .. len ].dup;
        zmq_msg_close( & msg );
        return data;
    }

    void send( char[] buf )
    {
        zmq_msg_t msg;
        assert( zmq_msg_init_size( & msg, buf.length ) == 0 );
        std.c.string.memcpy( zmq_msg_data( & msg ), buf.ptr, buf.length );
        assert( zmq_msg_send( & msg, zmqSock, 0 ) > -1 ); //send it off
        zmq_msg_close( & msg );
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

void usage( string name )
{
    writefln( "Usage: %s [options] TYPE address...", name );
    writefln( "where TYPE is one of (PUSH,PULL,PUB,SUB,REQ,REP,PAIR)" );
    writefln( "and [options] are:" );
    writefln( "\t-n|--num [nnn]\t\tLimit number of operations to [nnn]" );
    writefln( "\t-r|--read\t\tEnable read mode" );
    writefln( "\t-w|--write\t\tEnable write mode" );
    writefln( "\t-b|--bind\t\tBind to specified addresses..." );
    writefln( "\t-c|--connect\t\tConnect to specified addresses..." );
    writefln( "\t-o|--options [list]\tSet socket options from [list] in opt1=val1,opt2=val2 format" );
    writefln( "\t-h|--help\t\tThis help" );

    exit( 1 );
}

// ------------------------------------------------------------------------- //

int main( string[] args )
{
    bool nullDelim = false;
    int num = -1;
    bool readMode = false;
    bool writeMode = false;
    bool doBind = false;
    bool doConnect = false;
    bool showHelp = false;
    string[] options;

    getopt( args,
            "0", &nullDelim, 
            "n|num", &num,
            "r|read", &readMode,
            "w|write", &writeMode,
            "b|bind", &doBind,
            "c|connect", &doConnect,
            "o|options", &options,
            "h|help", &showHelp );

    if( showHelp )
        usage( args[ 0 ] );

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
            write( conn.receive() );
        }
        else if( st == SockType.REP )
        {
            write( conn.receive() );

            if( stdin.readln( buf, delim ) <= 0 )
                break;

            conn.send( buf );
        }
        else if( readMode )
        {
            write( "RECEIVE: ", conn.receive() );
        }
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


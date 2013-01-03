
module protocol.zsocket;

import std.stdio, std.conv, std.string;
public import zmq;

class ZSocket
{
    static void * zmqCtx;
    static string zmqIdent;

    static this()
    {
        //all ZSocket instances share a single ZMQ Context
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

    this( string addr, int type )
    {
        zmqSock = zmq_socket( zmqCtx, type );
        connect( addr );
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

        char[] data;
        if( len >= 0 )
        {
            data = cast(char[]) zmq_msg_data( & msg )[ 0 .. len ].dup;
            zmq_msg_close( & msg );
            debug writefln( "Received a message %d:%s", data.length, data );
        }
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


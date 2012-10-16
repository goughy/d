import std.stdio, std.string, std.regex, std.range, std.conv, std.math, std.stdint;
import std.getopt;
import std.file, std.path, std.socket, std.concurrency;

import protocol.http, protocol.ajp, protocol.mongrel2;

import core.sys.posix.signal;


auto debugLvl = 0;
auto quiet    = false;

auto totalListed = 0;
sigaction_t old_action;

bool shutdown = false;

// ------------------------------------------------------------------------- //

void msg( T ... ) ( int i, T opts )
{
    if( !quiet && i <= debugLvl )
    {
        writeln( "(I) ", opts );
    }
}

// ------------------------------------------------------------------------- //

void usage( string name )
{
    writeln();
    writeln( "Usage: ", name, " [options]" );
    writeln( "where [options] are:" );
    writeln();
    writeln( "\t--debug|-d lvl\t\tSet debug level to 'lvl'" );
    writeln( "\t--port|-p [n]\t\tAccept incoming connections on port [n]" );
    writeln( "\t\t\t\tDisplay this help message" );
}

// ------------------------------------------------------------------------- //

Tid tid;

extern(C) void sigint_handler( int sig_no )
{
    if( sig_no == SIGINT )
    {
        if( shutdown == true )
        {
            //force quit! this is the second time we've been asked
            writeln( "FORCING EXIT..." );
            std.c.stdlib.exit( 1 );
        }
        shutdown = true;
        writeln( "SIGINT - shutdown in process" );
        if( tid != Tid.init )
        {
            writefln( "Sending shutdown" );
            send( tid, 1 );
        }
    }
}

// ------------------------------------------------------------------------- //

void function( string address, ushort port, Tid tid ) asyncEntry;
void function( string address, ushort port, HttpResponse delegate(HttpRequest) dg ) syncEntry;

// ------------------------------------------------------------------------- //

int main( string[] args )
{
    string addr = "0.0.0.0:8888";
    ushort port = 8888;
    bool   sync = false;
    bool   http = true;
    bool   ajp  = false;
    bool   zmq  = false;
    getopt( args, 
            "a|addr", &addr,
            "s|sync", &sync,
            "http", &http,
            "ajp", &ajp,
            "zmq", &zmq );

    sigaction_t action;
    action.sa_handler = &sigint_handler;
    sigaction( SIGINT, &action, null );

    if( sync )
    {
        HttpResponse delegate(HttpRequest) dg = (HttpRequest req) => handleRequest( req ,"sync" );

        if( zmq )       mongrel2Serve( "127.0.0.1:8888", "127.0.0.1:8887", dg );
        else if( ajp )  ajpServe( addr, dg );
        else            httpServe( addr, dg );
    }
    else
    {
        if( zmq )       tid = spawnLinked( &mongrel2Serve, "127.0.0.1:8888", "127.0.0.1:8887", thisTid() );
        else if( ajp )  tid = spawnLinked( &ajpServe, addr, thisTid() );
        else            tid = spawnLinked( &httpServe, addr, thisTid() );

        while( !shutdown )
        {
            try
            {
                receive( 
                        ( string s )
                        {
                            writefln( "MAIN: %s", s );
                        },
                        ( HttpRequest req )         
                        { 
                            send( tid, handleRequest( req, "async" ) );
                        },
                        ( LinkTerminated e )
                        {
                            shutdown = true;
                            writeln( "Spawned thread terminated" );
                        });
            }
            catch( Throwable t )
            {
                writefln( "Caught exception waiting for msg: " ~ t.toString );
            }
        }
    }
   
    writeln( "Bye" );
    return 0;
}

// ------------------------------------------------------------------------- //


int idx = 0;
HttpResponse handleRequest( HttpRequest req, string type )
{
    debug writeln( "Handling HTTP request for URI: " ~ req.uri );
//    writeln( to!string( idx ) );
//    debug dump( req );

    //auto fn = pipe!( ok, header)
    HttpResponse resp = req.getResponse();
    //Response resp = new Response( req.connection );
    if( exists( req.uri[ 1 .. $ ] ) ) //strip leading '/'
    {
        resp.statusCode = 200;
        resp.statusMesg = "OK";

        if( req.method == Method.GET )
        {
            resp.addHeader( "Cache-Control", "public" );
            resp.data = cast(shared(ubyte[])) read( req.uri[ 1 .. $ ] );
        }
    }
    else if( match( req.uri, regex( "^/api/*" ) ).empty() )
    {
        resp.statusCode = 404;
        resp.statusMesg = "Not found (uri " ~ req.uri ~ " not supported)";
        return resp;
    }
    else
    {
        debug writefln( "(D) request data length %d", req.data.length );

        resp.statusCode = 200;
        resp.statusMesg = "OK";

        resp.addHeader( "Content-Type", "text/html; charset=utf-8" );
//        resp.addHeader( "Connection", "close" );
        //    resp.addHeader( "X-DAJP", "goughy" );

        if( req.method == Method.GET )
        {
            char[] d =
                "<html><head><title>DAJP - just what we were after</title>\n"
                "<body>\n"
                "   <h1>OK</h1>\n"
                "   <h3>" ~ type ~ " " ~ to !string( idx++ ) ~ "</h3>\n"
                "</body></html>\n".dup;

            foreach( k,v; httpStats )
                d ~= "<br>" ~ k ~ " = " ~ to!string( v );

            resp.data = cast(shared ubyte[]) d;
        }
    }
    debug writefln( "(D) sending return data length %d", resp.data.length );
    return resp;
}

// ------------------------------------------------------------------------- //



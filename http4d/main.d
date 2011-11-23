import std.stdio, std.string, std.regex, std.range, std.conv, std.math, std.stdint;
import std.getopt;
import std.file, std.path, std.socket, std.concurrency;

import protocol.ajp;
import protocol.http;

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
        shutdown = true;
        writeln( "SIGINT - shutdown in process" );
        if( tid != Tid.init )
            send( tid, 1 );
    }
    else if( sig_no == SIGUSR1 )
        writeln( "SIGUSR1!");
}

// ------------------------------------------------------------------------- //


int main( string[] args )
{

    if( args.length == 1 )
    {
        sigaction_t action;
        action.sa_handler = &sigint_handler;
        sigaction( SIGINT, &action, null );

//        tid = spawnLinked( &ajpServe, "0.0.0.0", cast(ushort) 8009, thisTid() );
//        setMaxMailboxSize( tid, 10000, OnCrowding.ignore );

        tid = spawnLinked( &httpServe, "0.0.0.0", cast(ushort) 8888, thisTid() );
//        setMaxMailboxSize( tid, 10000, OnCrowding.ignore );

//        setMaxMailboxSize( thisTid(), 10000, OnCrowding.ignore );

        while( !shutdown )
        {
            try
            {
                receiveTimeout( 1000,
                        ( string s )
                        {
                            writefln( "MAIN: %s", s );
                        },
                        ( Request req )         
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
    else
    {
        httpServe( "0.0.0.0", 8888, 
                (Request req)
                {
                    return handleRequest( req, "sync" );
                } );
    }
    
    writeln( "Bye" );
    return 0;
    
}

// ------------------------------------------------------------------------- //


int idx = 0;
Response handleRequest( Request req, string type )
{
    writeln( "Handling HTTP request for URI: " ~ req.uri );
//    writeln( to!string( idx ) );
//    dump( req );

    //auto fn = pipe!( ok, header)
    Response resp = req.getResponse();
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
    else if( match( req.uri, regex( "^/ajp*" ) ).empty() )
    {
        resp.statusCode = 404;
        resp.statusMesg = "Not found (uri " ~ req.uri ~ " not supported)";
        return resp;
    }
    else
    {
        resp.statusCode = 200;
        resp.statusMesg = "OK";

        resp.addHeader( "Content-Type", "text/html; charset=utf-8" );
        resp.addHeader( "Connection", "close" );
        //    resp.addHeader( "X-DAJP", "goughy" );

        if( req.method == Method.GET )
        {
            char[] d =
                "<html><head><title>DAJP - just what we were after</title>\n"
                "<body>\n"
                "   <h1>OK</h1>\n"
                "   <h3>Apparently these _are_ the " ~ type ~ " droids you're looking for (" ~ to !string( idx++ ) ~ ")</h3>\n"
                "</body></html>\n".dup;
            resp.data = cast(shared ubyte[]) d;
        }
    }
//    writefln( "(D) sending return data length %d", d.length );
    return resp;
}

// ------------------------------------------------------------------------- //



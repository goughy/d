
import std.stdio;
import protocol.http;
import std.concurrency, std.parallelism, std.conv;

int main( string[] args )
{
    string addr = "0.0.0.0";
    ushort port = 8888;

    auto tid = spawnLinked( &httpServe, "127.0.0.1", cast(ushort) 8888, thisTid() );
    bool shutdown = false;
    while( !shutdown )
    {
        receive( 
                ( string s )            { writefln( "MAIN: %s", s );                   },
                ( HttpRequest req )     { taskPool.put( task( &handleRequest, req ) ); },
                ( LinkTerminated e )    { shutdown = true;                             }
             );
    }

    return 0;
}

int sentinel = 0;
void handleRequest( HttpRequest req )
{
    debug writeln( "Handling HTTP request for URI: " ~ req.uri ~ " in thread id " ~ to!string( &sentinel ) );

    HttpResponse resp = req.getResponse();
    resp.statusCode = 200;
    resp.statusMesg = "OK";
    resp.addHeader( "Cache-Control", "public" );
    resp.data = cast( shared ubyte[] ) "<html><head></head><body><h1>Hi from HTTP-D!</h1></body></html>".dup;
    send( cast(Tid) req.tid, resp );
}


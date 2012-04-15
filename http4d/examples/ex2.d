
/**
 * This example is the simplest of all and just processes any request
 * by returning the same response.
 *
 * This is utilising the asynchronous interface with no dispatcher.
 */

import std.stdio, std.concurrency;
import protocol.http;

int main( string[] args )
{
    Tid tid = spawnLinked( &httpServe, "127.0.0.1", cast(ushort) 8888, thisTid() );

    bool shutdown = false;
    while( !shutdown )
    {
        try
        {
            receive( 
                ( string s ) { writefln( "MAIN: %s", s ); }, //process library logging
                ( shared(Request) req )         
                { 
                    send( tid, handleReq( req ) );
                },
                ( LinkTerminated e ) { shutdown = true; }
            );
        }
        catch( Throwable t )
        {
            writefln( "Caught exception waiting for msg: " ~ t.toString );
        }
    }
    return 0;
}

shared(Response) handleReq( shared(Request) req )
{
     return req.getResponse().
             status( 200 ).
             header( "Content-Type", "text/html" ).
             content( "<html><head></head><body>Processed asynchronously ok</body></html>" );
}


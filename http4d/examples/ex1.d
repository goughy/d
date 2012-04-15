
/**
 * This example is the simplest of all and just processes any request
 * by returning the same response.
 *
 * This is utilising the synchronous interface with no dispatcher.
 */
import std.stdio;
import protocol.http;

int main( string[] args )
{
    httpServe( "127.0.0.1", 8888,
                (req) => req.getResponse().
                            status( 200 ).
                            header( "Content-Type", "text/html" ).
                            content( "<html><head></head><body>Processed ok</body></html>" ) );
    return 0;
}


/**
 * This example utilises the MethodDispatch class to dispatch
 * to a nominated handler based on the HTTP method type.
 * 
 * Note that the Dispatch class provides a 'defaultHandler()'
 * function that enables the provision of a default handler 
 * should any registered handler fail to match the criteria
 */

import std.stdio;
import protocol.http;

RequestHandler oldDefault;

int main( string[] args )
{
    MethodDispatch dispatcher = new MethodDispatch;
    dispatcher.mount( Method.GET, &onGet );
    dispatcher.mount( Method.POST, &onPost );
 
    oldDefault = dispatcher.defaultHandler( &onDefault ); //specify your own default

    httpServe( "127.0.0.1", 8888, (req) => dispatcher( req ) );
    return 0;
}

shared(Response) onGet( shared(Request) req )
{
     return req.getResponse().
             status( 200 ).
             header( "Content-Type", "text/html" ).
             content( "<html><head></head><body>Processed GET request ok</body></html>" );
}

shared(Response) onPost( shared(Request) req )
{
    debug dump( req, "POST request contents" );
    return req.getResponse().error( 405 );
}

shared(Response) onDefault( shared(Request) req )
{
    if( req.method == Method.GET )
        return req.getResponse().ok().
                 header( "Content-Type", "text/html" ).
                 content( "<html><head></head><body>Looks like there is nothing here - maybe you should...</body></html>" );

    return oldDefault( req );
}


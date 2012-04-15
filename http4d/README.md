
HTTP4D
======

HTTP4D provides an easy entry point for providing embedded HTTP support
into any D application.  The library provides endpoints for the following

Supported Protocols:
    - HTTP (internal implementation)
    - AJP  (internal implementation but incomplete)
    - Mongrel2 (Relies on the ZMQ library)

It provides a very simple interface using request/response style making it very
easy to dispatch, route and handle a variety of web requests.

Example:

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
    
See the 'examples' folder for more.

In general no attempt is made to ensure compliance to the HTTP protocol as part of the response
as that is deemed the responsibility of the developer using the library.  That is, this library 
does not aim to be an HTTP/1.1 RFC 2616 compliant server, but rather an embeddable library 
that can expose an endpoint that may be interacted with via an HTTP client 
(such as a browser or programmatically eg. cURL).

This provides maximum flexibility to the developer, rather than implementing full server 
constraints.  It is expected that an application would **NOT** expose itself to the
internet, but access would be moderated via a process with better security credentials, such
as [Apache](http://httpd.apache.org/), [Nginx](http://www.nginx.org/), 
or [Mongrel2](http://mongrel2.org/).  The exception to this rule is with
respect to the "Connection" header, as that is used to determine the "keep-alive"
nature of the underlying socket connection - ie. set the "Connection" header to
"close" and the library will close the socket after transmitting the response.

That being said, by exposing an HTTP interface directly, systems may proxy requests through 
to a D application using this library incredibly easily. It also allows a
system architecture to be built using multiple independent processes
communicating via HTTP.

The library to process >23k requests per second using localhost on my 8GB 
quad core development machine **without** any additional tuning.

BUILDING
========
The build system I use is a modified (modified with D support) version of
[Premake](https://bitbucket.org/goughy/premake-dev-d/) and has been developed
solely using this system.

The only external dependency required is [Zeromq](http://www.zeromq.org/) as
this forms the basis of both the Mongrel2 support, and the core polling agent
for ordinary sockets. (And no, it doesn't use std.socket.select())

For convenience, the [Deimos](https://github.com/D-Programming-Deimos) Zeromq
files are provided in the 'src/deimos' folder, but it is possible they will
suffer bitrot.

Using Premake, the following should be all that's required:

    $ premake4 gmake
    $ make

and you will have a 'libcJSON.a' and a 'libhttp4d.a' library to link to for
your application.

If you do not wish to use Premake, the following commands are the underlying
build mechanics:

libcJSON
--------

    $ cc -MMD -MP  -Isrc -Isrc/cjson -g -Wall -Dddoc -o "obj/debug/cJSON/cJSON.o" -MF obj/debug/cJSON/cJSON.d -c "src/cjson/cJSON.c"
    $ ar -rcs ./libcJSON.a obj/debug/cJSON/cJSON.o 

libhttp4d
---------

    $ dmd -g -w  -lib -debug -Dddoc  -Isrc -Isrc/cjson -Isrc/deimos    -oflibhttp4d.a test.d src/protocol/ajp.d src/protocol/http.d src/protocol/mongrel2.d src/protocol/httpapi.d


License: [Boost License 1.0](http://boost.org/LICENSE_1_0.txt) 

Authors: [Andrew Gough](https://github.com/goughy)

Source: [github.com](https://github.com/goughy/d/tree/master/http4d)


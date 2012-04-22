
module luasp;
public import luad.all;
import luad.stack, luad.c.all;
import std.file, std.datetime, std.stream, std.stdio, std.conv;

enum LSP_WRITER    = "__luasp_writer";
enum LSP_USE_CACHE = "__luasp_usecache";
enum LSP_DSTATE    = "__luasp_state";

alias void function( in string s ) LspWriter;

LuaTable funcEnv;

// ------------------------------------------------------------------------- //

void stdoutWriter( in string s )
{
    write( s );
}

// ------------------------------------------------------------------------- //

class LspState
{
    this( LuaState state )
    {
        L = state;
    }

    void doLsp( string filename, LuaTable args, LspWriter writer = &stdoutWriter )
    {
        if( funcEnv.isNil ) 
        {
            //first time in this thread processing, so configure the per-thread
            //function environment
            funcEnv = L.newTable();

            //populate the new environment with the full global env alos: see http://www.lua.org/pil/14.3.html
            auto meta = L.newTable();
            meta[ "__index" ] = L.globals;
            funcEnv.setMetaTable( meta );

            funcEnv[ "dotmpl" ]         = &lsp_include;
            funcEnv[ "dofile_lsp" ]     = &lsp_include;
            funcEnv[ "echo" ]           = &lsp_echo;
            funcEnv[ "write" ]          = &lsp_echo;
            funcEnv[ "print" ]          = &lsp_print;
            funcEnv[ "log" ]            = &lsp_log;

            funcEnv[ "url_decode" ]     = &lsp_url_decode;
            funcEnv[ "args_decode" ]    = &lsp_args_decode;
            funcEnv[ "content_type" ]   = &lsp_content_type;
            funcEnv[ "set_out_header" ] = &lsp_set_out_header;
            funcEnv[ "get_in_header" ]  = &lsp_get_in_header;
            funcEnv[ "uuid_gen" ]       = &lsp_uuid_gen;
        }

        funcEnv[ LSP_WRITER ]    = writer;
        funcEnv[ LSP_USE_CACHE ] = cache_;

        funcEnv[ "args" ]        = args;
        funcEnv[ "env" ]         = env();

        lsp_include( filename );
    }

    @property LuaState state() { return L; }

    @property LuaTable env()
    {
        if( env_.isNil )
            env_ = L.newTable();

        return env_;
    }

    @property bool cache()          { return cache_; }
    @property void cache( bool c )  { cache_ = c;    }

private:

    LuaState  L;
    LuaTable  env_;
    bool      cache_;

    // ------------------------------------------------------------------------- //

    void lsp_include( in const(char[]) filename )
    {
        auto f = loadLsp( filename );
        f.setEnvironment( funcEnv );
        f();
    }

    // ------------------------------------------------------------------------- //

    void lsp_echo( LuaObject[] params... )
    {
        auto w = funcEnv[ LSP_WRITER ].to!LuaFunction;
        if( params.length > 0 )
        {
            foreach( param; params[ 0 .. $-1 ] )
            {
                w( param.toString );
                w( " " );
            }
            w( params[ $-1 ].toString );
        }
    }

    // ------------------------------------------------------------------------- //

    void lsp_print( LuaObject[] params... )
    {
        auto w = funcEnv[ LSP_WRITER ].to!LuaFunction;

        if( params.length > 0 )
        {
            foreach( param; params[ 0 .. $ - 1 ] )
            {
                w( param );
                w( "\t" );
            }
            w( params[ $ - 1 ] );
        }
        w( "\n" );
    }

    // ------------------------------------------------------------------------- //

    const(char[]) lsp_url_decode( immutable(char[]) url )
    {
        return decodeUrl( url );
    }

    // ------------------------------------------------------------------------- //

    void lsp_args_decode( const(char[]) args )
    {
    }

    // ------------------------------------------------------------------------- //

    void lsp_log( const(char[]) msg )
    {
        writeln( "LOG: ", msg );
    }

    // ------------------------------------------------------------------------- //

    void lsp_content_type( const(char[]) type )
    {
    }

    // ------------------------------------------------------------------------- //

    void lsp_set_out_header( const(char[]) key, const(char[]) value )
    {
    }

    // ------------------------------------------------------------------------- //

    void lsp_get_in_header( const(char[]) key )
    {
    }

    // ------------------------------------------------------------------------- //

    void lsp_uuid_gen()
    {
    }

    // ------------------------------------------------------------------------- //

    LuaFunction loadLsp( const(char[]) filename )
    {
        LuaFunction func;

        if( !cache_ )
            func = parseLsp( filename );
        else
        {
            string cacheFile = std.path.setExtension( std.path.stripExtension( filename ), "luac" );

            if( exists( cacheFile ) )
            {
                SysTime atime1, mtime1, atime2, mtime2;
                getTimes( filename, atime1, mtime1 );
                getTimes( cacheFile, atime2, mtime2 );

                if( mtime1 < mtime2 ) //cache file is still relevant
                    func = L.loadFile( cacheFile );
            }

            if( func.isNil )
            {
                //we need to parse the file, dump the compiled code, and then execute it
                func = parseLsp( filename );
                if( !func.isNil )
                {
                    std.stream.File cf = new std.stream.File( cacheFile, std.stream.FileMode.Out );
                    scope(exit) cf.close();
                    func.dump( (data) => cf.writeBlock( data.ptr, data.length ) == data.length );
                }
            }
        }

        return func;
    }

    // ------------------------------------------------------------------------- //

    LuaFunction parseLsp( const char[] filename )
    {
        return L.loadString( parseLspFile( filename ) );
    }

}

// ------------------------------------------------------------------------- //

scope struct ChDir
{
    this( const char[] path )
    {
        cwd = getcwd();
        chdir( path );
    }

    ~this()
    {
        if( cwd !is null )
            chdir( cwd );
    }

private:

    string cwd;
}

// ------------------------------------------------------------------------- //

const(char[]) parseLspFile( const(char[]) filename )
{
    immutable char chtype[ 256 ] =
    [
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x61, 0x62, 0x74, 0x6e, 0x76, 0x66, 0x72, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x00, 0x22, 0x00, 0x00, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5c, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ];

    enum Status 
    {
        echo1,
        echo2,
        echo3,
        echo4,
        stmt1,
        stmt12,
        stmt13,
        stmt2,
        stmt3,
        comment1,
        comment2,
        cr1,
        cr2,
    }

    auto outBuf = std.array.appender!(char[])();
    void putc( char c )
    {
        char ct = chtype[ c ];
        switch( ct )
        {
            case 0x00: 
                outBuf.put( c ); 
                break;

            case 0xff: 
                outBuf.put( '.' ); 
                break;

            default: 
                outBuf.put( '\\' ); 
                outBuf.put( ct ); 
                break;
        }
    }

    auto buf = cast(const(char[])) std.file.read( filename );

    uint currLine;
    outBuf.reserve( cast(ulong) (buf.length * 1.5) );

    Status st = Status.echo1;
    for( int i = 0; i < buf.length; ++i )
    {
        char ch = buf[ i ];
        if( ch == '\n' )
            currLine++;

        switch( st )
        {
            case Status.echo1:
                if( ch == '<' )
                    st = Status.echo4;
                else
                {
                    outBuf.put( "\necho('" ); //NB includes open quote
                    putc( ch );
                    st = Status.echo2;
                }
                break;
                       
            case Status.echo2:
	            if( ch == '<' )
		            st = Status.echo3;
	            else
                    putc( ch );
                break;

            case Status.echo3:
                if( ch == '?' )
                {
                    outBuf.put( "'); " );
                    st = Status.stmt1;
                }
                else
                {
                    outBuf.put( '<' );
                    putc( ch );
                    st = Status.echo2;
                }
                break;

            case Status.echo4:
                if( ch == '?' )
                    st = Status.stmt1;
                else
                {
                    outBuf.put( "\necho('<" );
                    putc( ch );
                    st = Status.echo2;
                }
                break;

            case Status.stmt1:
                if( ch == '=' )
                {
                    outBuf.put( "\necho(" ); //NB: no open quote
                    st = Status.stmt2;
                }
                else if( ch == '#' )
                    st = Status.comment1;
                else
                {
                    outBuf.put( ch ); //NB: no escaping
                    st = Status.stmt12;
                }
                break;

            case Status.stmt2:
                if( ch == '?' )
                    st = Status.stmt3;
                else
                    outBuf.put( ch ); //NB: no escaping
                break;

            case Status.stmt3:
                if( ch == '>' )
                {
                    outBuf.put( "); " );
                    st = Status.cr1;
                }
                else if( ch == '?' )
                    outBuf.put( '?' );
                else
                {
                    outBuf.put( '?' );
                    outBuf.put( ch ); //NB: no escaping
                    st = Status.stmt2;
                }
                break;

            case Status.stmt12:
                if( ch == '?' )
                    st = Status.stmt13;
                else
                    outBuf.put( ch ); //NB: no escaping
                break;

            case Status.stmt13:
                if( ch == '>' )
                {
                    outBuf.put( ' ' );
                    st = Status.cr1;
                }
                else if( ch == '?' )
                    outBuf.put( '?' );
                else
                {
                    outBuf.put( '?' );
                    outBuf.put( ch ); //NB: no escaping
                    st = Status.stmt12;
                }
                break;

            case Status.comment1:
                if( ch == '?' )
                    st = Status.comment2;
                break;

            case Status.comment2:
                if( ch == '>' )
                    st = Status.cr1;
                else if( ch != '?' )
                    st = Status.comment1;
                break;

            case Status.cr1:
                if( ch == '\r' )
                    st = Status.cr2;
                else
                {
                    if( ch != '\n' )
                        i--;

                    st = Status.echo1;
                }
                break;

            case Status.cr2:
                if( ch != '\n' )
                    i--;
                else
                    st = Status.echo1;
                break;

            default: 
                break;
        }

//        debug if( outBuf.data.length > 0 ) writefln( "In %x, last %x", ch, outBuf.data[ $ - 1 ] );
    }

    switch( st )
    {
        case Status.echo1:
        case Status.cr1:
        case Status.cr2:
            break;

        case Status.echo2:
            outBuf.put( "') " );
            break;

        default:
            //TODO: luaL_lsp_error(L); - what do we do in LuaD??
            break;
    }

    outBuf.put( '\n' );

//    debug writefln( "=== PARSED ===\n%s\n======", outBuf.data );
    return outBuf.data;
}

// ------------------------------------------------------------------------- //

const(char[]) decodeUrl( immutable(char[]) url )
{
    static immutable char hex[256] =
    [
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    ];

    auto buf = std.array.appender!(char[])();

    for( int i = 0; i < url.length; i++ )
    {
        immutable char c = url[ i ];
        switch( c )
        {
            case '+': 
                buf.put( ' ' ); 
                break;

            case '%':
                if( url.length >= i + 2 )
                {
                    immutable c1 = hex[ url[ ++i ] ];
                    immutable c2 = hex[ url[ ++i ] ];

                    if( c1 != 0xff && c2 != 0xff )
                        buf.put( cast(char) (((c1 << 4) & 0xf0) | (c2 & 0x0f)) );
                    else
                        buf.put( '.' );
                }
                break;

            default: 
                buf.put( c );
                break;
        }	
    }
    
    return buf.data;
}

// ------------------------------------------------------------------------- //

const(char[]) decodeArg( const(char[]) arg )
{
//    size_t offset1=0,length1=0;
//    size_t offset2=0,length2=0;
//
//    size_t i;
//
//    for(i=0;i<len;++i)
//    {    
//        if(p[i]=='=')
//        {
//            length1=i-offset1;
//            offset2=i+1;
//        }else if(p[i]=='&')
//        {
//            length2=i-offset2;
//
//            if(length1 && length2)
//            {	    
//                lua_pushlstring(L,p+offset1,length1);
//                urldecode(L,p+offset2,length2);
//                lua_rawset(L,-3);
//            }
//
//            offset1=i+1;
//            length1=offset2=length2=0;
//        }
//    }
//
//    length2=i-offset2;
//
//    if(length1 && length2)
//    {	    
//        lua_pushlstring(L,p+offset1,length1);
//        urldecode(L,p+offset2,length2);
//        lua_rawset(L,-3);
//    }

    return "";
}

debug void onPanic( LuaState L, in char[] msg )
{
    writefln( "PANIC: %s", msg );
}

unittest 
{
    writeln( "Unit test executing" );

    LuaState L = new LuaState;
    L.openLibs();
    L.setPanicHandler( &onPanic );

    LspState lsp = new LspState( L );

    //test URL decode
    assert( lsp.lsp_url_decode( "abc+def" ) == "abc def" );
    assert( lsp.lsp_url_decode( "abc%2C+def" ) == "abc, def" );
    assert( lsp.lsp_url_decode( "http://www.permadi.com/tutorial/urlEncoding/example.html?var=This+is+a+simple+%26+short+test." ) == "http://www.permadi.com/tutorial/urlEncoding/example.html?var=This is a simple & short test." );
    writeln( "Unit test finished" );
}

// Written in the D programming language

/**
 * Simple logging utility.
 *
 * Example:
 * -----
 * auto logger = Logger!(Log.formatter)("log.txt", 2);
 * logger.info("Information level");
 * logger.warn("Crash! - %s", program);
 * logger.write("raw message");
 * logger.close();
 * -----
 *
 * TTY Example:
 * -----
 * alias Logger!(Log.formatter, Log.colorize) TTYLogger;
 * auto logger = TTYLogger(stdout);
 * logger.info("Colorized Information");
 * -----
 *
 * Copyright: Copyright Masahiro Nakagawa 2010.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Masahiro Nakagawa
 */
module util.logger;


import std.file;      // exists, rename;
import std.process;   // getpid;
import std.stdio;     // File
import std.string;    // format, capitalize;
import std.conv;      // format, capitalize;
import std.typecons;  // defineEnum;
import std.datetime;  // getUTCtime, toString;


/**
 * Instead of namespace and some utilities.
 */
class Log
{
    /**
     * Supporting log levels.
     * Levels are "Trace", "Info", "Warn", "Error", "Fatal", "Unknown".
     * "Trace" level insteads of "Debug" because debug is D's keyword.
     */
    static enum Severity
    {
        Severity,
        Trace,
        Info,
        Warn,
        Error,
        Fatal,
        Unknown
    };


    /**
     * Filter for adding other detail information.
     *
     * Params:
     *  level = logging level.
     *  msg   = formatted message from logger.
     *
     * Returns:
     *  formatted message.
     */
    @trusted static string formatter( in Severity level, in string msg )
    {
        return format( "[%s#%d] %5s: %s", Clock.currTime(),
                       getpid(), to !string( level ), msg );
    }


    // colorize support for TTY

    private static string[Log.Severity] colorMap;

    static this( )
    {
        colorMap[Log.Severity.Trace]   = "\u001B[0;34m%s\u001B[0m";  // blue
        colorMap[Log.Severity.Info]    = "\u001B[0;37m%s\u001B[0m";  // white
        colorMap[Log.Severity.Warn]    = "\u001B[0;35m%s\u001B[0m";  // purple
        colorMap[Log.Severity.Error]   = "\u001B[0;33m%s\u001B[0m";  // yellow
        colorMap[Log.Severity.Fatal]   = "\u001B[0;31m%s\u001B[0m";  // red
        colorMap[Log.Severity.Unknown] = "\u001B[0;32m%s\u001B[0m";  // green
    }


    /**
     * Filter for adding coloring.
     *
     * Params:
     *  level = logging level.
     *  msg   = formatted message from logger.
     *
     * Returns:
     *  colorized message.
     */
    @trusted static string colorize( in Severity level, in string msg )
    {
        return format( colorMap[level], msg );
    }
}


/**
 * Simple logger
 *
 * $(D_PARAM formatters) are used for message customization. formatter signature is:
 * -----
 * string formatter(in Log.Severity level, in string msg)
 * -----
 */
struct Logger ( formatters ... )
{
    /**
     * $(D RotationWriter) supports age-based rotation. If $(D age) equals 0, no rotate.
     */
    struct RotationWriter
    {
private:
        File   file_;    // file to output

        // for rotation
        string name_;    // file name
        ulong  writed_;  // writed size
        uint   age_;     // rotation age
        ulong  size_;    // rotation file size


public:
        /**
         * Constructs $(D RotationWriter) with arguments.
         *
         * Params:
         *  file = file to output.
         *  age  = limit age  for rotation.
         *  size = limit size for rotation.
         */
        this( ref File file, uint age = 0, ulong size = 1024 * 1024 )
        {
            file_ = file;
            name_ = file.name;
            age_  = age;
            size_ = size;

            if( name_.length )
                writed_ = getSize( name_ );
        }


        /**
         * Writes a message.
         *
         * Params:
         *  msg = message to write.
         */
        @trusted void put( string msg )
        {
            // File or TTY?
            if( age_ && name_.length )
                rotate();

            file_.writeln( msg );

            writed_ += msg.length + 1;
        }


        /**
         * Closes output device.
         */
        @trusted void close()
        out
        {
            assert( !file_.isOpen );
        }
        body
        {
            file_.close();
        }


private:
        /**
         * Rotates log file.
         */
        @trusted void rotate()
        {
            if( writed_ > size_ )
            {
                // remove earliest log
                auto earliest = format( "%s.%d", name_, age_ - 1 );
                if( exists( earliest ))
                    remove( earliest );

                // increment age
                for( int i = age_ - 2; i >= 0; i-- )
                {
                    auto tempName = format( "%s.%d", name_, i );
                    if( exists( tempName ))
                        rename( tempName, format( "%s.%d", name_, i + 1 ));
                }

                file_.close();
                rename( name_, name_ ~ ".0" );
                file_   = File( name_, "a+" );
                writed_ = 0;
            }
        }
    }

    Log.Severity   severity;  /// logging level
    RotationWriter writer;    /// output writer

    alias          writer this;


    /**
     * Constructs $(D Logger) with arguments.
     * If $(D age) equals 0, no rotate.
     *
     * Params:
     *  filename = filename to log.
     *  age      = limit age  for rotation.
     *  size     = limit size for rotation.
     */
    this( string filename, uint age = 0, ulong size = 1024 * 1024 )
    {
        this( File( filename, "ab+" ), age, size );
    }


    /// ditto
    this( ref File file, uint age = 0, ulong size = 1024 * 1024 )
    {
        writer   = RotationWriter( file, age, size );
        severity = Log.Severity.Trace;
    }


    //~this() { writer.close; }  // trigger "bus error"


    /**
     * Sets a logging level from string. "Info", "INFO", "info", "InFO" are going to be all OK.
     *
     * Params:
     *  level = logging level.
     */
//    @trusted @property void level(string level)
//    {
//        Log.enumFromString(capitalize(level), severity);
//    }


    /**
     * Logs a formatted message. If $(D level) is smaller than pre-assigned level, no message.
     *
     * Params:
     *  level = logging level.
     *  fmt   = std.format specification string or log message.
     *  args  = format arguments.
     */
    @trusted void log( Args ... ) ( Log.Severity level, string fmt, Args args )
    {
        if( level < severity )
            return;

        string formatted = format( fmt, args );

        foreach( formatter; formatters )
            formatted = formatter( level, formatted );

        writer.put( formatted );
    }


    /**
     * Logs a method-name level. Shortcut of Logger.log method.
     *
     * Params:
     *  fmt  = std.format specification string or log message.
     *  args = format arguments.
     */
    @safe void trace( Args ... ) ( string fmt, Args args )
    {
        log( Log.Severity.Trace, fmt, args );
    }


    /// ditto
    @safe void info( Args ... ) ( string fmt, Args args )
    {
        log( Log.Severity.Info, fmt, args );
    }


    /// ditto
    @safe void warn( Args ... ) ( string fmt, Args args )
    {
        log( Log.Severity.Warn, fmt, args );
    }


    /// ditto
    @safe void error( Args ... ) ( string fmt, Args args )
    {
        log( Log.Severity.Error, fmt, args );
    }


    /// ditto
    @safe void fatal( Args ... ) ( string fmt, Args args )
    {
        log( Log.Severity.Fatal, fmt, args );
    }


    /// ditto
    @safe void unknown( Args ... ) ( string fmt, Args args )
    {
        log( Log.Severity.Unknown, fmt, args );
    }
}


unittest
{
    @trusted string myformatter( Log.Severity severity, string msg )
    {
        return format( "%5s: %s", to !string( severity ), msg );
    }

    struct Pair { Log.Severity level; string word; }
    static Pair[] pairs = [
        { Log.Severity.Trace, "aaa" },
        { Log.Severity.Info, "bbb" },
        { Log.Severity.Warn, "ccc" },
        { Log.Severity.Error, "ddd" },
        { Log.Severity.Fatal, "eee" }
    ];
    string[] results = [
        "Trace: " ~ pairs[0].word,
        " Info: " ~ pairs[1].word,
        " Warn: " ~ pairs[2].word,
        "Error: " ~ pairs[3].word,
        "Fatal: " ~ pairs[4].word
    ];

    auto filename = "foo.$$$";
    auto logger   = Logger!( myformatter )( filename );

    foreach( pair; pairs )
        logger.log( pair.level, pair.word );
    logger.close();

    auto f = File( filename );
    uint i;
    foreach( line; f.byLine())
        assert( line[0..10] == results[i++] );
    f.close();

    remove( filename );
}

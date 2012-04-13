--require "d"

solution "http4d"
    configurations { "debug", "release", "test" }
    includedirs { ".", "./cjson" } 

    configuration "debug"
        flags { "Symbols", "ExtraWarnings" }

    configuration { "debug", "D" }
        buildoptions "-gc"

    configuration "release"
        flags { "Optimize" }

    configuration "test"
        buildoptions "-unittest"
        flags { "Symbols", "ExtraWarnings" }

    project "cJSON"
        kind "StaticLib"
        language "C"
        files { "cjson/*.c" }

    project "http4d"
        kind "StaticLib"
        language "D"
        files { "*.d", "protocol/*.d", "util/*.d" }
        excludes { "main.d" }

    project "test"
        kind "ConsoleApp"
        language "D"
        files { "test.d" }
--        linkoptions "-L-L/usr/local/lib"
        links { "http4d", "cJSON", "zmq" }


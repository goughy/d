require "d"

solution "http4d"
    configurations { "debug", "release", "doc" }
--    location "build"
    includedirs { ".", "./cjson", "/data/devel-ext/dlang/deimos/ZeroMQ" } 
--    libdirs { "." }

    configuration "debug"
--        buildoptions "-v"
        flags { "Symbols", "ExtraWarnings" }

    configuration "release"
        flags { "Optimize" }

    configuration "doc"
        buildoptions "-D"

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
        files { "main.d" }
        links { "http4d", "cJSON" }
        linkoptions { "-L-lzmq" }

--require "d"

solution "http4d"
    configurations { "debug", "release", "test" }
    includedirs { "src", "src/cjson", "src/deimos" } 
    buildoptions "-Dddoc"

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
        files { "src/cjson/*.c" }

    project "http4d"
        kind "StaticLib"
        language "D"
        files { "*.d", "src/*.d", "src/protocol/*.d" }
        excludes { "main.d" }

    project "test"
        kind "ConsoleApp"
        language "D"
        files { "test.d" }
        links { "http4d", "cJSON", "zmq" }

    project "ex1"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex1.d" }
        links { "http4d", "cJSON", "zmq" }

    project "ex2"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex2.d" }
        links { "http4d", "cJSON", "zmq" }

    project "ex3"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex3.d" }
        links { "http4d", "cJSON", "zmq" }

    project "ex4"
        kind "ConsoleApp"
        language "D"
        files { "examples/ex4.d" }
        links { "http4d", "cJSON", "zmq" }



http4d = "/data/devel/d/http4d/src"

solution "zmqc"
    configurations { "debug", "release" }
    
    configuration "debug"
        flags { "Symbols", "ExtraWarnings" }

    configuration { "debug", "D" }
        buildoptions "-gc"

    configuration "release"
        flags { "Optimize" }

    project "zmqc"
        language "D"
        kind "ConsoleApp"
--        buildoptions { "-v" }
        includedirs { http4d, http4d .. "/deimos" }
        files { "src/*.d" }
        links { "zmq" }


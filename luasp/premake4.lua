
LuaD = "/data/devel-ext/LuaD";

solution "lsp"
    configurations { "debug" }
    includedirs { "./src", LuaD }
    libdirs { LuaD .. "/lib" }

    configuration "debug"
        flags { "Symbols", "ExtraWarnings" }
        buildoptions "-gc"

    configuration "release"
        flags { "Optimize" }

    project "lsp"
        kind "ConsoleApp"
        language "D"
        files { "test.d", "src/*.d" }
        links { "luad", "lua" }


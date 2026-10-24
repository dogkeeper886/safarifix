module github.com/dogkeeper886/safarifix/spike/esbuild-ios

go 1.13

require github.com/evanw/esbuild v0.28.2

// build.sh clones esbuild v0.28.2 here and checks its commit.
replace github.com/evanw/esbuild => ../../build/src/esbuild

// esbuild's pinned x/sys (2022-07-15) lacks darwin/arm, the 32-bit iPhone target; x/sys deleted it in 30e306a
// (2021-05-07), and its darwin/arm code stopped compiling at f992740 (2021-02-16, Xucred). This is the commit
// before that. esbuild uses only Stat, TimeToTimespec and the terminal-size ioctls from it, which it has.
replace golang.org/x/sys => golang.org/x/sys v0.0.0-20210216163648-f7da38b97c65

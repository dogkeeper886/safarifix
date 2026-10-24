module github.com/dogkeeper886/safarifix/core

// Go 1.14 is the last Go for 32-bit iPhones; keep the code within it.
go 1.13

require github.com/evanw/esbuild v0.28.2

// tools/deps.sh clones esbuild v0.28.2 here and checks its commit.
replace github.com/evanw/esbuild => ../build/src/esbuild

// esbuild's pinned x/sys lacks darwin/arm, the 32-bit iPhone target; this is the last version whose darwin/arm
// code compiles (see spike/esbuild-ios/go.mod).
replace golang.org/x/sys => golang.org/x/sys v0.0.0-20210216163648-f7da38b97c65

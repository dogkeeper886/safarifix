// Package main exports esbuild's transform to C, for the iPhone 5 build test: built with Go 1.14 as a
// c-archive for darwin/arm, it links into an Objective-C app, since an iOS app can't start esbuild as a process.
package main

// #include <stdlib.h>
import "C"

import "github.com/evanw/esbuild/pkg/api"

// SFTransform rewrites length bytes of JavaScript at code to the syntax Safari 10.1 on iOS 10.3 reads,
// with the same settings as bench/fix.py. It returns the new code, malloc'ed, with its size in outLen;
// on failure it returns NULL and sets errMsg, also malloc'ed. The caller frees both.
//export SFTransform
func SFTransform(code *C.char, length C.int, outLen *C.int, errMsg **C.char) *C.char {
	result := api.Transform(C.GoStringN(code, length), api.TransformOptions{
		Loader:  api.LoaderJS,
		Engines: []api.Engine{{Name: api.EngineIOS, Version: "10.3"}},
		// esbuild can't lower these for iOS 10, and Safari 10.1 runs them; see bench/fix.py.
		Supported:        map[string]bool{"const-and-let": true, "destructuring": true},
		MinifyWhitespace: true,
		Charset:          api.CharsetUTF8,
		LogLevel:         api.LogLevelSilent,
	})
	*outLen = 0
	*errMsg = nil
	if len(result.Errors) > 0 {
		*errMsg = C.CString(result.Errors[0].Text)
		return nil
	}
	*outLen = C.int(len(result.Code))
	return (*C.char)(C.CBytes(result.Code))
}

func main() {}

package fix

import (
	"strings"
	"testing"
)

func TestStylesheet(t *testing.T) {
	for _, c := range []struct{ name, in, want string }{
		{"layers unwrap in order, each later one gaining an ID",
			`@layer base,utilities;@layer utilities{.hidden{display:none}}@layer base{input:where([type=checkbox]){display:block}}.x{color:red}`,
			`.hidden:not(#\#){display:none;}input:matches([type=checkbox]){display:block;}.x:not(#\#):not(#\#){color:red;}`},
		{"the ID goes before a pseudo-element",
			`@layer a{}@layer b{.x::before,.y:after{content:''}}`,
			`.x:not(#\#)::before,.y:not(#\#):after{content:'';}`},
		{"selectors Safari can't match go, and unknown ones get rules of their own",
			`*,:before,::backdrop,.a:focus-visible,.b:-moz-focusring,.c:has(p),.d:fancy{margin:0}`,
			`*,:before{margin:0;}.d:fancy{margin:0;}`},
		{"an empty :is() or :where() matches nothing",
			`.a:is(),.b:before:where( ),.c:where(.d){color:red}`,
			`.c:matches(.d){color:red;}`},
		{"pseudos Safari knows by other names",
			`.a:is(.b),.c :where(p),:autofill,::file-selector-button{color:red}`,
			`.a:matches(.b),.c :matches(p),:-webkit-autofill,::-webkit-file-upload-button{color:red;}`},
		{"escaped colons stay in class names",
			`.focus-visible\:ring:hover,.has-\[\:checked\]\:x{color:red}`,
			`.focus-visible\:ring:hover,.has-\[\:checked\]\:x{color:red;}`},
		{"logical properties",
			`.a{padding-inline:1px 2px;margin-block:calc(var(--s) * 2);inset:0 1px;border-inline-start:1px solid red;border-block-width:2px}`,
			`.a{padding-left:1px;padding-right:2px;margin-top:calc(var(--s) * 2);margin-bottom:calc(var(--s) * 2);` +
				`top:0;right:1px;bottom:0;left:1px;border-left:1px solid red;border-top-width:2px;border-bottom-width:2px;}`},
		{"gap, place and the transforms",
			`.a{gap:1rem;column-gap:2px;place-items:center;translate:var(--x) var(--y);rotate:45deg;scale:none}`,
			`.a{grid-gap:1rem;grid-column-gap:2px;column-gap:2px;align-items:center;justify-items:center;` +
				`transform:translate(var(--x),var(--y));transform:rotate(45deg);}`},
		{"prefixes and keywords",
			`.a{position:sticky;appearance:none;text-decoration-line:underline;width:fit-content}`,
			`.a{position:-webkit-sticky;-webkit-appearance:none;-webkit-text-decoration-line:underline;width:-webkit-fit-content;}`},
		{"colors",
			`:root{--red:oklch(63.7% .237 25.331);--gray:oklch(55.1% 0.027 264.364);--black:oklch(0% 0 0 / 50%);` +
				`color:rgb(0 0 0 / 10%);background:hsl(210 40% 98%);border-color:rgb(1,2,3)}`,
			`:root{--red:#fb2c36;--gray:#6a7282;--black:#00000080;color:rgba(0,0,0,0.1);background:hsl(210,40%,98%);` +
				`border-color:rgb(1,2,3);}`},
		{"min, max and clamp on a 320-pixel screen",
			`.a{max-width:min(260px,100%);font-size:clamp(1.75rem,3vw,2.5rem);width:max(10px,5vw);` +
				`--g:clamp(2rem, (100vw - 90rem) * 1.2, 4rem);margin:min((100vw - 2rem) / 2, 1px)}`,
			`.a{max-width:260px;font-size:1.75rem;width:5vw;--g:2rem;margin:calc((100vw - 2rem) / 2);}`},
		{"a fully round corner",
			`.a{border-radius:calc(infinity * 1px)}`,
			`.a{border-radius:3.40282e38px;}`},
		{"@property goes, and @media and @supports stay",
			`@property --x{syntax:'*';inherits:false}@media (min-width:40rem){@supports (display:grid){.a{inset-inline:0}}}`,
			`@media (min-width:40rem){@supports (display:grid){.a{left:0;right:0;}}}`},
		{"media ranges",
			`@media (width>=40rem){.a{color:red}}@media not all and (width < 48rem){.b{color:red}}` +
				`@media (20rem <= width < 40rem),(height > 1px){.c{color:red}}`,
			`@media (min-width:40rem){.a{color:red;}}@media not all and (max-width:48rem){.b{color:red;}}` +
				`@media (min-width:20rem) and (max-width:40rem),(min-height:1px){.c{color:red;}}`},
		{"keyframes keep their selectors",
			`@layer a,b;@layer b{@keyframes spin{from{rotate:0deg}to{rotate:360deg}}}`,
			`@keyframes spin{from{transform:rotate(0deg);}to{transform:rotate(360deg);}}`},
		{"strings, comments and !important",
			`/* .b{} */.a{content:"x;y{}";color:red !important}`,
			`.a{content:"x;y{}";color:red!important;}`},
		{"statements stay",
			`@charset "utf-8";@import url(a.css);.a{color:red}`,
			`@charset "utf-8";@import url(a.css);.a{color:red;}`},
	} {
		if got, _ := stylesheet(c.in); got != c.want {
			t.Errorf("%s:\n got %s\nwant %s", c.name, got, c.want)
		}
	}
}

func TestStylesheetFlattensNesting(t *testing.T) {
	f, done := newFixer(t)
	defer done()
	out := string(f.Stylesheet([]byte(".a{padding-inline:0;&:hover{color:blue}}"), "test"))
	if out != ".a{padding-left:0;padding-right:0;}.a:hover{color:blue;}" {
		t.Errorf("nested rules: %s", out)
	}
}

func TestPageRewritesStyles(t *testing.T) {
	f, done := newFixer(t)
	defer done()
	html := `<html><head><style>@layer a{.x{inset:0}}</style>` +
		`<script>document.write("<style>.y{inset:0}</style>")</script></head></html>`
	out := string(f.Page([]byte(html), "test"))
	if !strings.Contains(out, "<style>.x{top:0;right:0;bottom:0;left:0;}</style>") {
		t.Errorf("style block not rewritten: %s", out)
	}
	if !strings.Contains(out, "<style>.y{inset:0}</style>") {
		t.Errorf("a script's string rewritten: %s", out)
	}
}

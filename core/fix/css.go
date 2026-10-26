package fix

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// stylesheet rewrites CSS into what Safari 10.1 reads. Tailwind CSS v4 puts every rule in an @layer block, names
// pseudo-elements and properties Safari 10.1 lacks, and gives its colors in oklch(); Safari drops each such block,
// rule or declaration whole, and the page shows unstyled. It reports whether css nests rules, which it leaves as
// they are.
func stylesheet(css string) (string, bool) {
	s := stripComments(css)
	sh := &sheet{layers: layerOrder(s)}
	// A } with no block to close ends a run of rules early.
	for i := 0; i < len(s); {
		i = sh.rules(s, i, "", false)
	}
	return sh.out.String(), sh.nested
}

type sheet struct {
	out strings.Builder
	// layers holds each layer's place in the cascade, by name.
	layers    map[string]int
	anonymous int
	nested    bool
}

// rules rewrites the rules from s[i] to the } that closes their block, or to the end of s, and returns the index
// after it.
func (sh *sheet) rules(s string, i int, layer string, keyframes bool) int {
	for i < len(s) {
		end := find(s, i, "{;}")
		prelude := strings.TrimSpace(s[i:end])
		if end < len(s) && s[end] == '{' {
			i = sh.block(prelude, s, end+1, layer, keyframes)
			continue
		}
		// @charset or @import; layerOrder has read @layer's list of names.
		if prelude != "" && atRule(prelude) != "layer" {
			sh.out.WriteString(prelude + ";")
		}
		if end == len(s) {
			return end
		}
		i = end + 1
		if s[end] == '}' {
			break
		}
	}
	return i
}

// block rewrites the block that starts at s[i], after prelude's {, and returns the index after the } that closes it.
func (sh *sheet) block(prelude, s string, i int, layer string, keyframes bool) int {
	name := atRule(prelude)
	switch {
	case keyframes:
	case name == "layer":
		return sh.rules(s, i, sh.layer(strings.TrimSpace(prelude[len("@layer"):])), false)
	case name == "media" || name == "supports" || name == "container" || name == "document" ||
		name == "keyframes" || name == "-webkit-keyframes":
		if name == "media" {
			prelude = mediaQuery(prelude)
		}
		sh.out.WriteString(prelude + "{")
		i = sh.rules(s, i, layer, strings.HasSuffix(name, "keyframes"))
		sh.out.WriteString("}")
		return i
	}
	close := closing(s, i-1)
	body := s[i:close]
	switch {
	case name == "" && !keyframes:
		sh.style(prelude, body, layer)
	case name == "property" || name == "starting-style" || name == "scope":
		// Safari 10.1 can't register a custom property, and Tailwind sets the initial values in a rule of their own
		// for browsers that can't. Safari drops the other two as it does an unknown rule.
	default:
		// A keyframe, @font-face or @page.
		sh.out.WriteString(prelude + "{" + declarations(body) + "}")
	}
	return min(close+1, len(s))
}

func (sh *sheet) style(prelude, body, layer string) {
	keep, alone := selectors(prelude)
	if find(body, 0, "{") < len(body) {
		sh.nested = true
	} else {
		body = declarations(body)
	}
	n := sh.boost(layer)
	if keep != "" {
		sh.out.WriteString(boost(keep, n) + "{" + body + "}")
	}
	for _, sel := range alone {
		sh.out.WriteString(boost(sel, n) + "{" + body + "}")
	}
}

// layer returns the name of a layer block, naming an anonymous one by its place among them as layerOrder does.
func (sh *sheet) layer(name string) string {
	if name == "" {
		sh.anonymous++
		name = "#" + strconv.Itoa(sh.anonymous)
	}
	return name
}

// layerOrder returns the place in the cascade of each layer css names, by the order the names first appear in. A
// layer nested in another counts as one of its own.
func layerOrder(css string) map[string]int {
	order := map[string]int{}
	anonymous := 0
	for {
		at := strings.Index(css, "@layer")
		if at < 0 {
			return order
		}
		css = css[at+len("@layer"):]
		end := strings.IndexAny(css, "{;")
		if end < 0 {
			return order
		}
		names := strings.Split(css[:end], ",")
		if strings.TrimSpace(css[:end]) == "" {
			anonymous++
			names = []string{"#" + strconv.Itoa(anonymous)}
		}
		for _, name := range names {
			if name = strings.TrimSpace(name); order[name] == 0 {
				order[name] = len(order) + 1
			}
		}
	}
}

// boost returns how many IDs a rule in layer gains. The rules of a later layer beat an earlier one's whatever their
// selectors, and rules in no layer beat them all; Safari 10.1 knows no layers, and compares only the selectors.
// Tailwind relies on it: its utilities' single classes override its base rules for elements.
func (sh *sheet) boost(layer string) int {
	if layer == "" {
		return len(sh.layers)
	}
	return sh.layers[layer] - 1
}

// boost adds n IDs to a selector's specificity with :not(#\#), which matches any element but one whose id is "#".
func boost(sel string, n int) string {
	if n == 0 {
		return sel
	}
	ids := strings.Repeat(`:not(#\#)`, n)
	var out []string
	for _, s := range split(sel, ',') {
		// Before the pseudo-element, which ends a selector.
		at := len(s)
		for i := 0; i < len(s); i++ {
			if j := skip(s, i); j != i {
				i = j - 1
				continue
			}
			if s[i] == ':' && pseudoElement(s[i:]) {
				at = i
				break
			}
		}
		out = append(out, s[:at]+ids+s[at:])
	}
	return strings.Join(out, ",")
}

func pseudoElement(s string) bool {
	lower := strings.ToLower(s)
	for _, p := range []string{"::", ":before", ":after", ":first-line", ":first-letter"} {
		if strings.HasPrefix(lower, p) {
			return true
		}
	}
	return false
}

// atRule returns the lower-case name of the at-rule that starts with prelude, or "" for a style rule.
func atRule(prelude string) string {
	if !strings.HasPrefix(prelude, "@") {
		return ""
	}
	name := strings.ToLower(prelude[1:])
	if i := strings.IndexAny(name, " \t\n({"); i >= 0 {
		name = name[:i]
	}
	return name
}

var (
	ranges       = regexp.MustCompile(`\(\s*([^()<>=]+?)\s*(<=?)\s*(width|height)\s*(<=?)\s*([^()<>=]+?)\s*\)`)
	rangeAfter   = regexp.MustCompile(`\(\s*(width|height)\s*([<>]=?)\s*([^()<>=]+?)\s*\)`)
	rangeBefore  = regexp.MustCompile(`\(\s*([^()<>=]+?)\s*([<>]=?)\s*(width|height)\s*\)`)
	flippedRange = strings.NewReplacer("<", ">", ">", "<")
)

// mediaQuery writes a media query's ranges, such as (width >= 40rem), as the min- and max- features Safari 10.1
// reads. A strict < or > takes in its bound.
func mediaQuery(prelude string) string {
	prelude = ranges.ReplaceAllString(prelude, "(min-$3:$1) and (max-$3:$5)")
	prelude = rangeBefore.ReplaceAllStringFunc(prelude, func(m string) string {
		p := rangeBefore.FindStringSubmatch(m)
		return limit(p[3], flippedRange.Replace(p[2]), p[1])
	})
	return rangeAfter.ReplaceAllStringFunc(prelude, func(m string) string {
		p := rangeAfter.FindStringSubmatch(m)
		return limit(p[1], p[2], p[3])
	})
}

func limit(feature, op, bound string) string {
	if strings.HasPrefix(op, ">") {
		return "(min-" + feature + ":" + bound + ")"
	}
	return "(max-" + feature + ":" + bound + ")"
}

// pseudos says what to do with each pseudo-class and pseudo-element in a selector, by name: drop the selector
// ("-"), rename it, or keep it (""). Safari 10.1 drops a whole rule for one selector it doesn't know; a name not
// listed gets the selector a rule of its own, so it can't take the rule's other selectors with it.
var pseudos = map[string]string{
	"where": "matches", "is": "matches", "autofill": "-webkit-autofill", "file-selector-button": "-webkit-file-upload-button",

	"has": "-", "focus-visible": "-", "marker": "-", "backdrop": "-", "popover-open": "-", "open": "-", "modal": "-",
	"user-invalid": "-", "user-valid": "-", "dir": "-", "state": "-", "target-text": "-", "details-content": "-",

	"active": "", "after": "", "any-link": "", "before": "", "checked": "", "default": "", "disabled": "", "empty": "",
	"enabled": "", "first-child": "", "first-letter": "", "first-line": "", "first-of-type": "", "focus": "",
	"focus-within": "", "host": "", "hover": "", "indeterminate": "", "invalid": "", "lang": "", "last-child": "",
	"last-of-type": "", "link": "", "matches": "", "not": "", "nth-child": "", "nth-last-child": "",
	"nth-last-of-type": "", "nth-of-type": "", "only-child": "", "only-of-type": "", "optional": "", "placeholder": "",
	"placeholder-shown": "", "read-only": "", "read-write": "", "required": "", "root": "", "selection": "",
	"target": "", "valid": "", "visited": "",
}

// selectors rewrites a selector list. It returns the selectors to keep in the rule, and the ones to give rules of
// their own.
func selectors(list string) (keep string, alone []string) {
	var kept []string
	for _, sel := range split(list, ',') {
		sel, known, ok := selector(strings.TrimSpace(sel))
		switch {
		case !ok:
		case known:
			kept = append(kept, sel)
		default:
			alone = append(alone, sel)
		}
	}
	return strings.Join(kept, ","), alone
}

// selector rewrites one selector's pseudo-classes and pseudo-elements. ok is false when Safari 10.1 can't use the
// selector, and known is false when it names one pseudos doesn't list.
func selector(sel string) (out string, known, ok bool) {
	var b strings.Builder
	known = true
	for i := 0; i < len(sel); {
		if j := skip(sel, i); j != i {
			b.WriteString(sel[i:j])
			i = j
			continue
		}
		if sel[i] != ':' {
			b.WriteByte(sel[i])
			i++
			continue
		}
		j := i + 1
		if j < len(sel) && sel[j] == ':' {
			j++
		}
		k := j
		for k < len(sel) && isNameByte(sel[k]) {
			k++
		}
		b.WriteString(sel[i:j])
		name := strings.ToLower(sel[j:k])
		to, listed := pseudos[name]
		switch {
		case to == "-" || strings.HasPrefix(name, "-moz-") || strings.HasPrefix(name, "-ms-"):
			return "", false, false
		case (to == "matches" || name == "matches") && emptyList(sel[k:]):
			// An empty :is() or :where() matches nothing, and Safari 10.1 drops an empty :matches() with its rule.
			return "", false, false
		case to != "":
			b.WriteString(to)
		default:
			if !listed && !strings.HasPrefix(name, "-webkit-") {
				known = false
			}
			b.WriteString(sel[j:k])
		}
		i = k
	}
	return b.String(), known, true
}

// emptyList reports whether s starts with an empty selector list in parentheses.
func emptyList(s string) bool {
	return strings.HasPrefix(s, "(") && strings.TrimSpace(s[1:find(s, 1, ")")]) == ""
}

type declaration struct{ name, value string }

// sides maps the logical properties Safari 10.1 lacks to their physical sides on a left-to-right page.
var sides = func() map[string][]string {
	m := map[string][]string{
		"inset":        {"top", "right", "bottom", "left"},
		"inset-inline": {"left", "right"}, "inset-inline-start": {"left"}, "inset-inline-end": {"right"},
		"inset-block": {"top", "bottom"}, "inset-block-start": {"top"}, "inset-block-end": {"bottom"},
	}
	for _, p := range []string{"padding", "margin", "border"} {
		for _, suffix := range []string{"", "-width", "-style", "-color"} {
			if p != "border" && suffix != "" {
				continue
			}
			side := func(s string) string { return p + "-" + s + suffix }
			m[p+"-inline"+suffix] = []string{side("left"), side("right")}
			m[p+"-inline-start"+suffix] = []string{side("left")}
			m[p+"-inline-end"+suffix] = []string{side("right")}
			m[p+"-block"+suffix] = []string{side("top"), side("bottom")}
			m[p+"-block-start"+suffix] = []string{side("top")}
			m[p+"-block-end"+suffix] = []string{side("bottom")}
		}
	}
	return m
}()

// prefixed are the properties Safari 10.1 knows only by their -webkit- names.
var prefixed = map[string]bool{
	"appearance": true, "user-select": true, "backdrop-filter": true, "clip-path": true, "text-decoration-line": true,
	"text-decoration-style": true, "text-decoration-color": true, "print-color-adjust": true, "text-size-adjust": true,
	"hyphens": true, "box-decoration-break": true, "mask": true, "mask-image": true, "mask-size": true,
	"mask-position": true, "mask-repeat": true,
}

// declarations rewrites a block's declarations.
func declarations(block string) string {
	var b strings.Builder
	for _, d := range split(block, ';') {
		colon := find(d, 0, ":")
		if colon == len(d) {
			continue
		}
		name := strings.TrimSpace(d[:colon])
		if !strings.HasPrefix(name, "--") {
			name = strings.ToLower(name)
		}
		v := strings.TrimSpace(d[colon+1:])
		important := ""
		if i := strings.LastIndexByte(v, '!'); i >= 0 && strings.EqualFold(strings.TrimSpace(v[i+1:]), "important") {
			v, important = strings.TrimSpace(v[:i]), "!important"
		}
		for _, d := range longhands(name, value(v)) {
			b.WriteString(d.name + ":" + d.value + important + ";")
		}
	}
	return b.String()
}

// longhands returns the declarations Safari 10.1 reads for one it may not.
func longhands(name, v string) []declaration {
	if to, ok := sides[name]; ok {
		values := []string{v}
		if !strings.HasPrefix(name, "border-") || strings.HasSuffix(name, "-width") || strings.HasSuffix(name, "-style") ||
			strings.HasSuffix(name, "-color") {
			values = fields(v)
		}
		var ds []declaration
		for i, side := range to {
			ds = append(ds, declaration{side, box(values, i, len(to))})
		}
		return ds
	}
	switch name {
	case "gap":
		return []declaration{{"grid-gap", v}}
	case "row-gap":
		return []declaration{{"grid-row-gap", v}}
	case "column-gap":
		return []declaration{{"grid-column-gap", v}, {name, v}}
	case "place-items", "place-content", "place-self":
		values := fields(v)
		what := strings.TrimPrefix(name, "place-")
		return []declaration{{"align-" + what, box(values, 0, 2)}, {"justify-" + what, box(values, 1, 2)}}
	case "translate", "scale":
		if v == "none" {
			return nil
		}
		f := fields(v)
		if name == "translate" && len(f) == 3 {
			return []declaration{{"transform", "translate3d(" + strings.Join(f, ",") + ")"}}
		}
		return []declaration{{"transform", name + "(" + strings.Join(f, ",") + ")"}}
	case "rotate":
		if f := fields(v); len(f) == 1 && v != "none" {
			return []declaration{{"transform", "rotate(" + v + ")"}}
		}
		return nil
	case "position":
		if strings.EqualFold(v, "sticky") {
			return []declaration{{name, "-webkit-sticky"}}
		}
	}
	switch strings.ToLower(v) {
	case "fit-content", "min-content", "max-content":
		v = "-webkit-" + strings.ToLower(v)
	}
	if prefixed[name] {
		return []declaration{{"-webkit-" + name, v}}
	}
	return []declaration{{name, v}}
}

// box returns side i of n from the values of a shorthand, as for margin: one value sets every side, and a missing
// one copies the side opposite.
func box(values []string, i, n int) string {
	if len(values) == 0 {
		return ""
	}
	if n == 4 {
		switch {
		case i >= len(values) && i == 3 && len(values) >= 2:
			return values[1]
		case i >= len(values) && i == 2:
			return values[0]
		}
	}
	if i >= len(values) {
		return values[0]
	}
	return values[i]
}

// value rewrites a declaration's value: the colors in oklch(), and min(), max() and clamp().
func value(v string) string {
	var b strings.Builder
	for i := 0; i < len(v); {
		if j := skip(v, i); j != i {
			b.WriteString(v[i:j])
			i = j
			continue
		}
		if !isNameByte(v[i]) || (i > 0 && isNameByte(v[i-1])) {
			b.WriteByte(v[i])
			i++
			continue
		}
		k := i
		for k < len(v) && isNameByte(v[k]) {
			k++
		}
		if k == len(v) || v[k] != '(' {
			b.WriteString(v[i:k])
			i = k
			continue
		}
		end := find(v, k+1, ")")
		name := strings.ToLower(v[i:k])
		if name == "url" {
			b.WriteString(v[i:min(end+1, len(v))])
		} else {
			b.WriteString(function(name, v[i:k], value(v[k+1:end])))
		}
		i = end + 1
	}
	return b.String()
}

// function rewrites one function in a value, given its arguments already rewritten.
func function(name, raw, args string) string {
	switch name {
	case "oklch", "oklab":
		if c, ok := okColor(name == "oklch", args); ok {
			return c
		}
	case "rgb", "rgba", "hsl", "hsla":
		if c, ok := legacyColor(strings.TrimSuffix(name, "a"), args); ok {
			return c
		}
	case "calc":
		if strings.Replace(strings.ToLower(args), " ", "", -1) == "infinity*1px" {
			return "3.40282e38px"
		}
	case "min", "max", "clamp":
		return pick(name, split(args, ','))
	}
	return raw + "(" + args + ")"
}

// pick stands in for min(), max() and clamp(), which Safari 10.1 lacks, with the argument that wins on the
// iPhone 5's 320-pixel-wide screen, or the first when it can't tell.
func pick(name string, args []string) string {
	for i := range args {
		args[i] = strings.TrimSpace(args[i])
	}
	px := make([]float64, len(args))
	all := true
	for i, a := range args {
		var ok bool
		if px[i], ok = pixels(a); !ok {
			all = false
		}
	}
	best := 0
	switch {
	case name == "clamp" && len(args) == 3 && all:
		best = 1
		if px[1] < px[0] {
			best = 0
		} else if px[1] > px[2] {
			best = 2
		}
	case name != "clamp" && all:
		for i := range px {
			if (name == "min") == (px[i] < px[best]) && px[i] != px[best] {
				best = i
			}
		}
	}
	a := args[best]
	if len(fields(a)) > 1 || strings.HasPrefix(a, "(") || find(a, 0, "*/") < len(a) {
		return "calc(" + a + ")"
	}
	return a
}

// pixels returns a length's size on the iPhone 5 in portrait, where a percentage is taken of the screen's width.
func pixels(length string) (float64, bool) {
	units := []struct {
		unit string
		px   float64
	}{{"px", 1}, {"rem", 16}, {"em", 16}, {"vw", 3.2}, {"vh", 5.68}, {"%", 3.2}}
	for _, u := range units {
		if strings.HasSuffix(length, u.unit) {
			n, err := strconv.ParseFloat(strings.TrimSuffix(length, u.unit), 64)
			return n * u.px, err == nil
		}
	}
	n, err := strconv.ParseFloat(length, 64)
	return n, err == nil && n == 0
}

// okColor converts oklch() or oklab() to a hex color in sRGB, lowering the chroma of a color outside sRGB.
func okColor(polar bool, args string) (string, bool) {
	c, alpha, ok := colorArgs(args)
	if !ok {
		return "", false
	}
	l, ok1 := number(c[0], 1)
	x, ok2 := number(c[1], 0.4)
	y, ok3 := number(c[2], 0.4)
	if polar {
		h, ok := number(strings.TrimSuffix(c[2], "deg"), 0)
		if !ok {
			return "", false
		}
		x, y, ok3 = x*math.Cos(h*math.Pi/180), x*math.Sin(h*math.Pi/180), true
	}
	if !ok1 || !ok2 || !ok3 {
		return "", false
	}
	rgb := oklabToLinear(l, x, y)
	if !inGamut(rgb) {
		lo, hi := 0.0, 1.0
		for i := 0; i < 20; i++ {
			mid := (lo + hi) / 2
			if inGamut(oklabToLinear(l, x*mid, y*mid)) {
				lo = mid
			} else {
				hi = mid
			}
		}
		rgb = oklabToLinear(l, x*lo, y*lo)
	}
	hex := "#"
	for _, ch := range rgb {
		if ch <= 0.0031308 {
			ch *= 12.92
		} else {
			ch = 1.055*math.Pow(ch, 1/2.4) - 0.055
		}
		hex += fmt.Sprintf("%02x", int(math.Round(math.Max(0, math.Min(1, ch))*255)))
	}
	if alpha < 1 {
		hex += fmt.Sprintf("%02x", int(math.Round(alpha*255)))
	}
	return hex, true
}

func oklabToLinear(l, a, b float64) [3]float64 {
	l_ := math.Pow(l+0.3963377774*a+0.2158037573*b, 3)
	m := math.Pow(l-0.1055613458*a-0.0638541728*b, 3)
	s := math.Pow(l-0.0894841775*a-1.2914855480*b, 3)
	return [3]float64{
		4.0767416621*l_ - 3.3077115913*m + 0.2309699292*s,
		-1.2684380046*l_ + 2.6097574011*m - 0.3413193965*s,
		-0.0041960863*l_ - 0.7034186147*m + 1.7076147010*s,
	}
}

func inGamut(rgb [3]float64) bool {
	for _, c := range rgb {
		if c < -0.0001 || c > 1.0001 {
			return false
		}
	}
	return true
}

// legacyColor writes rgb() and hsl() with spaces, or with an alpha, in the commas Safari 10.1 reads.
func legacyColor(name, args string) (string, bool) {
	commas := strings.Count(args, ",")
	if strings.Contains(args, "var(") || !strings.Contains(args, "/") && commas != 0 && commas != 3 {
		return "", false
	}
	c, alpha, ok := colorArgs(strings.Replace(args, ",", " ", -1))
	if !ok {
		return "", false
	}
	if alpha < 1 {
		return name + "a(" + strings.Join(c, ",") + "," + strconv.FormatFloat(alpha, 'f', -1, 64) + ")", true
	}
	return name + "(" + strings.Join(c, ",") + ")", true
}

// colorArgs splits a color function's arguments into its three components and its alpha.
func colorArgs(args string) (c []string, alpha float64, ok bool) {
	parts := strings.SplitN(args, "/", 2)
	c = fields(parts[0])
	alpha = 1
	if len(parts) == 2 {
		if alpha, ok = number(strings.TrimSpace(parts[1]), 1); !ok {
			return nil, 0, false
		}
	} else if len(c) == 4 {
		if alpha, ok = number(c[3], 1); !ok {
			return nil, 0, false
		}
		c = c[:3]
	}
	return c, alpha, len(c) == 3
}

// number parses a number, or a percentage of percent.
func number(s string, percent float64) (float64, bool) {
	if s == "none" {
		return 0, true
	}
	scale := 1.0
	if strings.HasSuffix(s, "%") {
		s, scale = s[:len(s)-1], percent/100
	}
	n, err := strconv.ParseFloat(s, 64)
	return n * scale, err == nil
}

// fields splits a value at its spaces outside parentheses.
func fields(v string) []string {
	var f []string
	for _, part := range split(strings.Join(strings.Fields(v), " "), ' ') {
		if part != "" {
			f = append(f, part)
		}
	}
	return f
}

// skip returns the index after the string or escape that starts at s[i], or i when none does.
func skip(s string, i int) int {
	switch s[i] {
	case '\\':
		return min(i+2, len(s))
	case '"', '\'':
		for j := i + 1; j < len(s); j++ {
			switch s[j] {
			case '\\':
				j++
			case s[i], '\n':
				return j + 1
			}
		}
		return len(s)
	}
	return i
}

// find returns the index of the first of chars at or after s[i] outside strings, parentheses and brackets, or
// len(s).
func find(s string, i int, chars string) int {
	var stop [256]bool
	for j := 0; j < len(chars); j++ {
		stop[chars[j]] = true
	}
	depth := 0
	for i < len(s) {
		switch c := s[i]; {
		case c == '\\' || c == '"' || c == '\'':
			i = skip(s, i)
			continue
		case depth == 0 && stop[c]:
			return i
		case c == '(' || c == '[':
			depth++
		case (c == ')' || c == ']') && depth > 0:
			depth--
		}
		i++
	}
	return len(s)
}

// closing returns the index of the } that closes the { at s[i], or len(s).
func closing(s string, i int) int {
	depth := 0
	for i < len(s) {
		switch s[i] {
		case '\\', '"', '\'':
			i = skip(s, i)
			continue
		case '{':
			depth++
		case '}':
			if depth--; depth == 0 {
				return i
			}
		}
		i++
	}
	return len(s)
}

// split splits s at each sep outside strings, parentheses and brackets.
func split(s string, sep byte) []string {
	var parts []string
	for {
		i := find(s, 0, string(sep))
		parts = append(parts, s[:i])
		if i == len(s) {
			return parts
		}
		s = s[i+1:]
	}
}

func stripComments(s string) string {
	if !strings.Contains(s, "/*") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		j := strings.IndexAny(s[i:], `/"'\`)
		if j < 0 {
			b.WriteString(s[i:])
			break
		}
		b.WriteString(s[i : i+j])
		i += j
		if j := skip(s, i); j != i {
			b.WriteString(s[i:j])
			i = j
			continue
		}
		if strings.HasPrefix(s[i:], "/*") {
			end := strings.Index(s[i+2:], "*/")
			if end < 0 {
				break
			}
			i += end + 4
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}

func isNameByte(c byte) bool {
	return c == '-' || c == '_' || c >= 0x80 || '0' <= c && c <= '9' || 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z'
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

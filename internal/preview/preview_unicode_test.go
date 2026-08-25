package preview

import "testing"

// A title in any script must produce a usable matching key. The ASCII-only
// filter reduced every fully non-Latin title to the empty string, and an
// empty key matches nothing -- those songs were unreachable.
func TestNormalizeKeepsNonLatinScripts(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Stupid For You", "stupidforyou"},
		{"[16] Stupid_For-You!", "16stupidforyou"},
		{"満月の夜に", "満月の夜に"},
		{"КАТЮША", "катюша"},
		{"ウィザウチュナイ -type ZERO-", "ウィザウチュナイtypezero"},
		{"1998", "1998"},
	}
	for _, c := range cases {
		if got := normalize(c.in); got != c.want {
			t.Errorf("normalize(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	if normalize("満月の夜に") == "" {
		t.Fatal("a non-Latin title still normalizes to nothing")
	}
}

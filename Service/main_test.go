package main

import (
	"context"
	"net/http/httptest"
	"testing"
)

func TestRejectUnsafeURLs(t *testing.T) {
	for _, u := range []string{"http://example.com", "file:///etc/passwd", "https://127.0.0.1", "https://user:pass@example.com"} {
		if _, e := fetch(context.Background(), u); e == nil {
			t.Fatalf("accepted %s", u)
		}
	}
}
func TestPlain(t *testing.T) {
	s := plain("<p>Hello</p><script>bad()</script><p>World</p>")
	if s != "Hello\n\nWorld" {
		t.Fatalf("got %q", s)
	}
}
func TestMethod(t *testing.T) {
	w := httptest.NewRecorder()
	handler(w, httptest.NewRequest("POST", "/feed", nil))
	if w.Code != 405 {
		t.Fatal(w.Code)
	}
}

func TestExtractionFallback(t *testing.T) {
	a := Article{Title: "Preserved", URL: "http://blocked.invalid", Text: "Feed content"}
	if got := enrich(context.Background(), a); got != a {
		t.Fatalf("lost fallback: %+v", got)
	}
}
func TestChannelValidation(t *testing.T) {
	for _, s := range []string{"", "../admin", "https://t.me/test", "channel?x=y"} {
		if _, err := telegram(context.Background(), s); err == nil {
			t.Fatalf("accepted %q", s)
		}
	}
}

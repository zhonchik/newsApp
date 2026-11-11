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

func TestRSSContentAndDate(t *testing.T) {
	fixture := `<rss version="2.0"><channel><title>News</title><item><guid>one</guid><title>Story</title><link>https://example.com/story</link><pubDate>Wed, 11 Nov 2026 12:00:00 GMT</pubDate><description><![CDATA[<p>Body</p>]]></description></item></channel></rss>`
	items, err := parseRSS([]byte(fixture))
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].ID != "one" || items[0].Text != "Body" || items[0].Published.IsZero() {
		t.Fatalf("unexpected items: %+v", items)
	}
}
func TestTelegramTextAndPermalink(t *testing.T) {
	fixture := `<div class="tgme_widget_message" data-post="example/42"><div class="tgme_widget_message_text">Hello<br>World</div><time datetime="2026-11-11T12:00:00+00:00"></time></div>`
	items, err := parseTelegram([]byte(fixture))
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].URL != "https://t.me/example/42" || items[0].Text != "Hello\n\nWorld" {
		t.Fatalf("unexpected posts: %+v", items)
	}
}

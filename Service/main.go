package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	readability "codeberg.org/readeck/go-readability/v2"
	"github.com/PuerkitoBio/goquery"
	"github.com/mmcdole/gofeed"
)

type Article struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	URL       string    `json:"url"`
	Text      string    `json:"text"`
	Published time.Time `json:"published"`
}

// Resolve and validate every connection, including redirect targets, to prevent SSRF.
func publicDial(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil {
		return nil, err
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("no address")
	}
	for _, ip := range ips {
		if !ip.IP.IsGlobalUnicast() || ip.IP.IsPrivate() || ip.IP.IsLoopback() || ip.IP.IsLinkLocalUnicast() {
			return nil, fmt.Errorf("non-public address")
		}
	}
	return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ips[0].IP.String(), port))
}

var client = &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{DialContext: publicDial}, CheckRedirect: func(r *http.Request, via []*http.Request) error {
	if len(via) >= 5 {
		return fmt.Errorf("too many redirects")
	}
	if r.URL.Scheme != "https" {
		return fmt.Errorf("HTTPS required")
	}
	return nil
}}

func fetch(ctx context.Context, raw string) ([]byte, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return nil, fmt.Errorf("a public HTTPS URL is required")
	}
	req, err := http.NewRequestWithContext(ctx, "GET", raw, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "CurrentReader/1.0")
	res, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("publisher returned %d", res.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, (5<<20)+1))
	if len(b) > 5<<20 {
		return nil, fmt.Errorf("response exceeds 5 MiB")
	}
	return b, err
}
func plain(html string) string {
	d, e := goquery.NewDocumentFromReader(strings.NewReader(html))
	if e != nil {
		return html
	}
	d.Find("script,style").Remove()
	d.Find("p,br,div").Each(func(_ int, s *goquery.Selection) { s.AfterHtml("\n\n") })
	return strings.TrimSpace(d.Text())
}
func enrich(ctx context.Context, a Article) Article {
	b, e := fetch(ctx, a.URL)
	if e != nil {
		return a
	}
	u, _ := url.Parse(a.URL)
	r, e := readability.FromReader(strings.NewReader(string(b)), u)
	if e != nil {
		return a
	}
	var out strings.Builder
	if r.RenderHTML(&out) == nil {
		if t := plain(out.String()); t != "" {
			a.Text = t
		}
	}
	return a
}
func rss(ctx context.Context, raw string) ([]Article, error) {
	b, e := fetch(ctx, raw)
	if e != nil {
		return nil, e
	}
	return parseRSS(b)
}
func parseRSS(b []byte) ([]Article, error) {
	f, e := gofeed.NewParser().ParseString(string(b))
	if e != nil {
		return nil, e
	}
	out := []Article{}
	for _, i := range f.Items {
		d := i.PublishedParsed
		if d == nil {
			d = i.UpdatedParsed
		}
		if d == nil {
			continue
		}
		t := i.Content
		if t == "" {
			t = i.Description
		}
		id := i.GUID
		if id == "" {
			id = i.Link
		}
		if id == "" {
			continue
		}
		out = append(out, Article{id, i.Title, i.Link, plain(t), *d})
	}
	return out, nil
}
func telegram(ctx context.Context, channel string) ([]Article, error) {
	channel = strings.TrimPrefix(channel, "@")
	if channel == "" || strings.ContainsAny(channel, "/?# .") {
		return nil, fmt.Errorf("enter a public channel username")
	}
	b, e := fetch(ctx, "https://t.me/s/"+url.PathEscape(channel))
	if e != nil {
		return nil, e
	}
	return parseTelegram(b)
}
func parseTelegram(b []byte) ([]Article, error) {
	d, e := goquery.NewDocumentFromReader(strings.NewReader(string(b)))
	if e != nil {
		return nil, e
	}
	out := []Article{}
	d.Find(".tgme_widget_message").Each(func(_ int, s *goquery.Selection) {
		id, _ := s.Attr("data-post")
		text := plainHTMLSelection(s.Find(".tgme_widget_message_text"))
		rawDate, _ := s.Find("time").Attr("datetime")
		date, e := time.Parse(time.RFC3339, rawDate)
		if e != nil || text == "" || id == "" {
			return
		}
		title := strings.SplitN(text, "\n", 2)[0]
		if len([]rune(title)) > 100 {
			title = string([]rune(title)[:100]) + "…"
		}
		out = append(out, Article{id, title, "https://t.me/" + id, text, date})
	})
	if len(out) == 0 {
		return nil, fmt.Errorf("no public text posts found; channel may be private or unavailable")
	}
	return out, nil
}
func plainHTMLSelection(s *goquery.Selection) string { h, _ := s.Html(); return plain(h) }
func handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != "GET" {
		http.Error(w, "GET required", 405)
		return
	}
	var out []Article
	var err error
	switch r.URL.Path {
	case "/feed":
		if r.URL.Query().Get("kind") == "telegram" {
			out, err = telegram(r.Context(), r.URL.Query().Get("url"))
		} else {
			out, err = rss(r.Context(), r.URL.Query().Get("url"))
		}
	case "/article":
		a := enrich(r.Context(), Article{URL: r.URL.Query().Get("url")})
		json.NewEncoder(w).Encode(a)
		return
	default:
		http.NotFound(w, r)
		return
	}
	if err != nil {
		w.WriteHeader(502)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	json.NewEncoder(w).Encode(out)
}
func main() {
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	s := &http.Server{Addr: addr, Handler: http.HandlerFunc(handler), ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
	log.Printf("Current service: %s", addr)
	log.Fatal(s.ListenAndServe())
}

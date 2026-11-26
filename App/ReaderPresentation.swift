enum ReaderPresentation {
    static func navigation(initialOffset: Double) -> String {
        """
        let restoring = Number(document.documentElement.getAttribute('data-reader-scroll') ?? \(initialOffset));
        const restoreUntil = Date.now() + 8000;
        const reportScroll = () => window.webkit.messageHandlers.readerScroll.postMessage(window.scrollY);
        const restore = () => {
          if (restoring === null) return;
          window.scrollTo(0, restoring);
          if (Date.now() >= restoreUntil) { restoring = null; reportScroll(); }
        };
        const stopRestore = () => { restoring = null; };
        for (const type of ['touchstart', 'pointerdown', 'wheel', 'keydown'])
          document.addEventListener(type, stopRestore, {passive: true});
        new ResizeObserver(restore).observe(document.body);
        setTimeout(restore, 8100);
        window.addEventListener('scroll', () => { if (restoring === null) reportScroll(); }, {passive: true});
        document.addEventListener('click', event => {
          const link = event.target.closest('a[href]');
          if (!link) return;
          event.preventDefault();
          reportScroll();
          window.webkit.messageHandlers.readerLink.postMessage({url: link.href, external: link.hasAttribute('data-reader-original-link')});
        });
        """
    }

    // Run in WebKit’s isolated client world after parsing the local article.
    static let afterFirstFrame = """
        requestAnimationFrame(function() { requestAnimationFrame(function() {
          const key = document.documentElement.getAttribute('data-reader-key');
          if (!key) return;
          window.webkit.messageHandlers.readerReady.postMessage(key);
          for (const element of document.querySelectorAll('img[data-reader-src],iframe[data-reader-src]')) {
            element.setAttribute('src', element.getAttribute('data-reader-src'));
            element.removeAttribute('data-reader-src');
          }
          for (const video of document.querySelectorAll('video[data-reader-poster]')) {
            video.setAttribute('poster', video.getAttribute('data-reader-poster'));
            video.removeAttribute('data-reader-poster');
          }
        }); });
        """
}

enum ReaderPresentation {
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

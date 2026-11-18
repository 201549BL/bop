if (["localhost", "127.0.0.1", "[::1]"].includes(location.hostname)) {
  const link = document.querySelector("[data-local-download]");
  link.href = link.dataset.localDownload;
  link.download = "";
}

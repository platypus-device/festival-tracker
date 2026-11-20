const downloadStatus = document.querySelector("#downloadStatus");
const downloadLink = document.querySelector("#downloadLink");

async function openTorrentDownload() {
  const hash = new URLSearchParams(window.location.search).get("hash")?.toLowerCase();
  if (!hash || !/^[a-f0-9]{40}$/.test(hash)) throw new Error("Invalid torrent hash");

  const response = await fetch("../data/yts-downloads.json", { cache: "no-store" });
  if (!response.ok) throw new Error("Download index unavailable");
  const urls = await response.json();
  const target = new URL(urls[hash]);
  if (target.protocol !== "https:" || target.username || target.password || target.port ||
      target.pathname.toLowerCase() !== `/torrent/download/${hash}`) throw new Error("Invalid download address");

  downloadLink.href = target.href;
  downloadLink.hidden = false;
  downloadStatus.textContent = "Opening the YTS download…";
  window.location.replace(target.href);
}

openTorrentDownload().catch(() => {
  downloadStatus.textContent = "No download address is available for this torrent.";
});

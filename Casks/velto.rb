cask "velto" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Varell-co/Velto/releases/download/v#{version}/Velto-#{version}-universal.zip"
  name "Velto"
  desc "Prometheus and Grafana Mimir alerts in the menu bar and terminal"
  homepage "https://github.com/Varell-co/Velto"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "Velto.app"
  # The CLI ships inside the app, so the menu bar and the terminal always run the same version.
  binary "#{appdir}/Velto.app/Contents/Helpers/velto"

  # The app is ad-hoc signed and not notarized, so a quarantined copy will not open.
  # Clearing the flag for this one app is the opt-in trust decision made by installing the cask.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Velto.app"],
        writable_paths: ["Velto.app"],
        writable_base:  :appdir
  end

  uninstall quit: "co.varell.velto"

  zap trash: [
    "~/Library/Application Support/co.varell.velto",
    "~/Library/Preferences/co.varell.velto.plist",
  ]
end

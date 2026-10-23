# Beszel Monitoring Stack

Beszel (`beszel-hub` and `beszel-agent`) provides cluster & host metrics visualization.

## Hub Custom Layout

The hub web UI is customized to arrange the system detail dashboard as follows:
- **Row 1:** CPU Usage (left) | Memory / System RAM (right)
- **Row 2:** GPU Usage (left, under CPU) | GPU VRAM Usage (right, under Memory)
- **Row 3:** Temperature (left) | GPU Power Draw (right)
- Subsequent rows: Container CPU/Memory, Disk, Network, Load Average, Swap, Fan, etc.

### Patch and Custom Binary

The Vite/React frontend in Beszel is statically embedded into the single Go binary at compile time via Go's `//go:embed`.

The patch [`dashboard-layout.patch`](dashboard-layout.patch) modifies:
- `internal/site/src/components/routes/system/charts/gpu-charts.tsx`: exports `GpuUsageAndVramCharts` (paired cards for GPU Usage and VRAM).
- `internal/site/src/components/routes/system.tsx`: updates `defaultLayout` and `tabbedLayout` to place CPU & Memory in Row 1, GPU & VRAM in Row 2, Temperature & GPU Power Draw in Row 3.

### Rebuilding the Binary

```bash
git clone --branch v0.21.0 https://github.com/henrygd/beszel.git /tmp/beszel
cd /tmp/beszel
git apply <path-to>/dashboard-layout.patch

# Build frontend
cd internal/site
npm install
npm run build

# Build static Go hub binary
cd /tmp/beszel
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-w -s" -o beszel ./internal/cmd/hub

# Stage to host storage on Watchtower
scp beszel watchtower:/mnt/appdata/beszel/bin/beszel
ssh watchtower "chmod 755 /mnt/appdata/beszel/bin/beszel"
```

The Kubernetes deployment mounts `/beszel` using `subPath: bin/beszel` from the `beszel-hub-data` PVC (`/mnt/appdata/beszel`), overriding the standard container binary.

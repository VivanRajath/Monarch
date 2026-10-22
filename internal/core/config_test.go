package core

import (
	"strings"
	"testing"
	"time"
)

func clearMonarchEnv(t *testing.T) {
	for _, k := range []string{"MONARCH_LISTEN_ADDR", "MONARCH_PUBLIC_ORIGIN", "MONARCH_PREVIEW_DOMAIN", "MONARCH_PREVIEW_SCHEME", "MONARCH_WORK_DIR",
		"MONARCH_BETA_CODE", "MONARCH_SESSION_SECRET", "MONARCH_MAX_SANDBOXES", "MONARCH_MAX_PER_USER", "MONARCH_LLM_PER_HOUR",
		"MONARCH_SANDBOX_IDLE_TTL", "MONARCH_SANDBOX_MAX_TTL", "MONARCH_SPAWN_AGENT", "AGENT_PORT",
		"MONARCH_CONTAINER_CLI", "MONARCH_PREHEAT_IMAGES", "MONARCH_MIN_FREE_DISK_MB", "MONARCH_INTERNAL_TOKEN", "MONARCH_PREVIEW_MODE", "MONARCH_CLOUDFLARED", "MONARCH_DISK_CHECK_PATHS", "MONARCH_SANDBOX_MAX_DISK_MB"} {
		t.Setenv(k, "")
	}
}

func TestLoadConfigDefaultsMatchLocalDev(t *testing.T) {
	clearMonarchEnv(t)
	c, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if c.ListenAddr != "127.0.0.1:9000" || c.Public() || c.AuthEnabled() || c.PreviewDomain != "" {
		t.Fatalf("defaults drifted from local dev: %+v", c)
	}
	if c.MaxPerUser != 0 || c.LLMPerHour != 0 || !c.SpawnAgent || c.AgentPort != 8001 || c.ListenPort() != "9000" {
		t.Fatalf("local mode should not cap users or skip the agent: %+v", c)
	}
	if c.IdleTTL != 15*time.Minute || c.MaxTTL != 45*time.Minute {
		t.Fatalf("ttl defaults = %s/%s", c.IdleTTL, c.MaxTTL)
	}
}

func TestLoadConfigPublicMode(t *testing.T) {
	clearMonarchEnv(t)
	t.Setenv("MONARCH_PUBLIC_ORIGIN", "https://monarch.example/")
	t.Setenv("MONARCH_PREVIEW_DOMAIN", "MONARCH.example.")
	t.Setenv("MONARCH_BETA_CODE", "letmein")
	t.Setenv("MONARCH_SESSION_SECRET", strings.Repeat("s", 32))
	t.Setenv("MONARCH_SANDBOX_IDLE_TTL", "10m")
	c, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if c.PublicOrigin != "https://monarch.example" || c.PreviewDomain != "monarch.example" || c.PreviewScheme != "https" {
		t.Fatalf("public origin/preview not normalised: %+v", c)
	}
	if c.MaxPerUser != 1 || c.LLMPerHour != 60 || c.IdleTTL != 10*time.Minute {
		t.Fatalf("public defaults not applied: %+v", c)
	}
}

func TestLoadConfigFailsClosed(t *testing.T) {
	cases := map[string]map[string]string{
		"public without login":   {"MONARCH_PUBLIC_ORIGIN": "https://monarch.example", "MONARCH_PREVIEW_DOMAIN": "monarch.example"},
		"public without preview": {"MONARCH_PUBLIC_ORIGIN": "https://monarch.example", "MONARCH_BETA_CODE": "x", "MONARCH_SESSION_SECRET": strings.Repeat("s", 32)},
		"short secret":           {"MONARCH_BETA_CODE": "x", "MONARCH_SESSION_SECRET": "short"},
		"idle above max":         {"MONARCH_SANDBOX_IDLE_TTL": "50m"},
		"bad number":             {"MONARCH_MAX_SANDBOXES": "lots"},
		"bad duration":           {"MONARCH_SANDBOX_MAX_TTL": "soon"},
	}
	for name, env := range cases {
		t.Run(name, func(t *testing.T) {
			clearMonarchEnv(t)
			for k, v := range env {
				t.Setenv(k, v)
			}
			if _, err := LoadConfig(); err == nil {
				t.Fatal("expected LoadConfig to refuse this configuration")
			}
		})
	}
}

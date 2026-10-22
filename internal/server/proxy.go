package server

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path"
	"strings"
	"time"

	"sandbox/internal/core"
)

// Only Go calls these, straight on the loopback port; /agent/register takes an arbitrary host workdir.
var internalAgentPaths = map[string]bool{"/agent/register": true, "/agent/keys": true}

func agentProxyHandler() http.Handler {
	return newAgentProxy(fmt.Sprintf("http://127.0.0.1:%d", core.Cfg.AgentPort))
}

// newAgentProxy reverse-proxies /agent/* (REST and the /agent/ws WebSocket) to the Node agent service.
func newAgentProxy(targetURL string) http.Handler {
	target, _ := url.Parse(targetURL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	// Idle connections close before Node's 5s keep-alive does, so a request never lands on a socket Node just closed.
	proxy.Transport = &http.Transport{
		DialContext:         (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
		IdleConnTimeout:     4 * time.Second,
		MaxIdleConnsPerHost: 16,
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		core.Logf("agent", "proxy %s %s failed: %v", r.Method, r.URL.Path, err)
		core.CORS(w, r)
		core.JSONError(w, "Agent service unavailable: "+err.Error(), 502)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		core.CORS(w, r)
		if r.Method == http.MethodOptions {
			return
		}
		if internalAgentPaths[strings.ToLower(path.Clean(r.URL.Path))] {
			http.NotFound(w, r)
			return
		}
		// Node trusts these for ownership and to know the call came through Go; client copies never survive.
		r.Header.Set("X-Monarch-User", core.UserOf(r))
		r.Header.Set("X-Monarch-Internal", core.Cfg.InternalToken)
		r.Header.Del("Cookie")
		proxy.ServeHTTP(w, r)
	})
}

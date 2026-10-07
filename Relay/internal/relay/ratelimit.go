package relay

import (
	"net/netip"
	"sync"
	"time"
)

// rateLimiter allows each source address `limit` data connections in any
// window. Entries whose window has passed are swept as the map grows, so a
// scan from many addresses costs a bounded map.
type rateLimiter struct {
	limit  int
	window time.Duration

	mu    sync.Mutex
	seen  map[netip.Addr][]time.Time
	sweep time.Time
}

func newRateLimiter(limit int, window time.Duration) *rateLimiter {
	return &rateLimiter{limit: limit, window: window, seen: map[netip.Addr][]time.Time{}}
}

func (r *rateLimiter) allow(addr netip.Addr, now time.Time) bool {
	if r.limit <= 0 {
		return true
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	cutoff := now.Add(-r.window)
	if now.Sub(r.sweep) > r.window {
		for a, times := range r.seen {
			if !times[len(times)-1].After(cutoff) {
				delete(r.seen, a)
			}
		}
		r.sweep = now
	}
	times := r.seen[addr]
	i := 0
	for i < len(times) && !times[i].After(cutoff) {
		i++
	}
	times = times[i:]
	if len(times) >= r.limit {
		r.seen[addr] = times
		return false
	}
	r.seen[addr] = append(times, now)
	return true
}

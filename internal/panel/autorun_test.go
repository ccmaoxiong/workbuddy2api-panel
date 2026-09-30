package panel

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/linguo2625469/workbuddy2api-panel/internal/auth"
	"github.com/linguo2625469/workbuddy2api-panel/internal/pool"
	"github.com/linguo2625469/workbuddy2api-panel/internal/upstream"
)

// autoStatusOf 直接调 handler 取一份自动执行状态（跳过 HTTP 鉴权）。
func autoStatusOf(t *testing.T, p *Panel) autoTaskStatus {
	t.Helper()
	rec := httptest.NewRecorder()
	p.autoTasksStatusHandler(rec, httptest.NewRequest("GET", "/panel/api/tasks/auto", nil))
	if rec.Code != 200 {
		t.Fatalf("status handler → %d", rec.Code)
	}
	var st autoTaskStatus
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatalf("decode status: %v", err)
	}
	return st
}

func autoPost(t *testing.T, p *Panel, body string) autoTaskStatus {
	t.Helper()
	rec := httptest.NewRecorder()
	p.autoTasksConfigHandler(rec, httptest.NewRequest("POST", "/panel/api/tasks/auto", strings.NewReader(body)))
	if rec.Code != 200 {
		t.Fatalf("POST %s → %d %s", body, rec.Code, rec.Body.String())
	}
	var st autoTaskStatus
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatalf("decode status: %v", err)
	}
	return st
}

// 默认状态：开启、2 小时、首轮 90s 后——自动执行开箱即用，且不与手动队列抢跑。
func TestAutoTasksDefaults(t *testing.T) {
	p := New(Config{Version: "test"})
	st := autoStatusOf(t, p)
	if !st.Enabled {
		t.Fatal("默认应开启")
	}
	if want := int(autoTaskDefaultInterval / time.Minute); st.IntervalMinutes != want {
		t.Fatalf("默认间隔=%d 分钟，期望 %d", st.IntervalMinutes, want)
	}
	if st.Runs != 0 || st.QueueRunning || st.LastStarted {
		t.Fatalf("初始不应有运行记录：%+v", st)
	}
	if d := time.Until(st.NextAt); d < 60*time.Second || d > 2*time.Minute {
		t.Fatalf("首轮应在 90s 后，实际 %v", d)
	}
}

// 热改开关与间隔：间隔夹取到 [5m, 24h]；重新开启后安排一轮补跑。
func TestAutoTasksConfigClampAndReschedule(t *testing.T) {
	p := New(Config{Version: "test"})

	if st := autoPost(t, p, `{"enabled":false}`); st.Enabled {
		t.Fatal("关闭后应 enabled=false")
	}
	if st := autoPost(t, p, `{"interval_minutes":1}`); st.IntervalMinutes != 5 {
		t.Fatalf("间隔下限应夹到 5 分钟，实际 %d", st.IntervalMinutes)
	}
	if st := autoPost(t, p, `{"interval_minutes":99999}`); st.IntervalMinutes != 1440 {
		t.Fatalf("间隔上限应夹到 1440 分钟，实际 %d", st.IntervalMinutes)
	}
	// 关闭状态下改间隔不动 nextAt；重新开启才排补跑。
	st := autoPost(t, p, `{"enabled":true,"interval_minutes":60}`)
	if !st.Enabled || st.IntervalMinutes != 60 {
		t.Fatalf("重新开启 + 改间隔应同时生效：%+v", st)
	}
	if d := time.Until(st.NextAt); d < 30*time.Second || d > 2*time.Minute {
		t.Fatalf("重新开启应安排补跑一轮（约 90s），实际 %v 后", d)
	}
}

// 非法 body 返回 400 且不改动状态。
func TestAutoTasksConfigRejectsBadBody(t *testing.T) {
	p := New(Config{Version: "test"})
	rec := httptest.NewRecorder()
	p.autoTasksConfigHandler(rec, httptest.NewRequest("POST", "/panel/api/tasks/auto", strings.NewReader("{")))
	if rec.Code != 400 {
		t.Fatalf("坏 body 应 400，实际 %d", rec.Code)
	}
	if !autoStatusOf(t, p).Enabled {
		t.Fatal("坏 body 不应改动状态")
	}
}

// 未装配账号池时自动轮不 panic，只记一轮空跑（裁剪部署/测试路径）。
func TestAutoTasksRunWithoutPoolIsSafe(t *testing.T) {
	p := New(Config{Version: "test"})
	p.runAutoTasksOnce()
	st := autoStatusOf(t, p)
	if st.Runs != 1 || st.LastStarted || st.LastSkipped {
		t.Fatalf("空跑应记 runs=1 且未启动队列：%+v", st)
	}
}

// 手动队列在跑时自动轮命中同一 queueState，本轮跳过而非并发双开。
func TestAutoTasksSkipsWhenQueueBusy(t *testing.T) {
	p := New(Config{Version: "test"})
	q := p.queue()
	q.mu.Lock()
	q.running = true
	q.mu.Unlock()
	st := autoStatusOf(t, p)
	if !st.QueueRunning {
		t.Fatal("queue_running 应透出手动队列占用")
	}
}

// 路由与鉴权：/panel/api/tasks/auto 已挂载，且走面板统一的 Bearer 鉴权。
func TestAutoTasksRouteRegistered(t *testing.T) {
	p := New(Config{Version: "test", APIKey: "secret"})
	rec := httptest.NewRecorder()
	p.ServeHTTP(rec, httptest.NewRequest("GET", "/panel/api/tasks/auto", nil))
	if rec.Code != 401 {
		t.Fatalf("无 key 应 401，实际 %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/panel/api/tasks/auto", nil)
	req.Header.Set("Authorization", "Bearer secret")
	p.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("带 key 应 200，实际 %d（%s）", rec.Code, rec.Body.String())
	}
	var st autoTaskStatus
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !st.Enabled {
		t.Fatal("默认应开启")
	}
}

// 自动轮端到端：桩上游下发一个待办任务 → runAutoTasksOnce 走「执行全部待办」
// 同管线，队列被真正启动并执行完（同步扫描阶段就应有条目，不依赖人工点击）。
func TestAutoTasksRunsGrowthQueue(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/activity/growth/tasks") {
			w.Write([]byte(`{"code":0,"msg":"OK","data":{"tasks":[{"task_code":"Library_read","title":"读资料库","target":1,"current":1,"accept_status":"accepted"}]}}`))
			return
		}
		w.Write([]byte(`{"code":0,"msg":"OK","data":{}}`))
	}))
	defer srv.Close()

	up := &upstream.Client{HTTP: srv.Client(), ChatBaseCN: srv.URL, BillingBaseCN: srv.URL, WebBaseCN: srv.URL}
	pl := pool.New("")
	pl.Add(&auth.Auth{UID: "u1", Nickname: "甲", AccessToken: "at", ExpiresAt: 9999999999})

	pn := New(Config{Version: "test", Pool: pl, Upstream: up})
	pn.runAutoTasksOnce()

	st := autoStatusOf(t, pn)
	if !st.LastStarted || st.LastTotal < 1 {
		t.Fatalf("自动轮应启动队列并排队 ≥1 项：%+v", st)
	}
	q := pn.queue()
	q.mu.Lock()
	items := len(q.items)
	q.mu.Unlock()
	if items < 1 {
		t.Fatalf("队列条目=%d，期望 ≥1", items)
	}
	// 等后台执行收尾，避免 goroutine 越过用例边界继续打桩上游。
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		q.mu.Lock()
		running := q.running
		q.mu.Unlock()
		if !running {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("自动队列未在 10s 内收尾")
}

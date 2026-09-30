// autorun.go 任务自动化：把「任务中心」的手动扫描 + 执行合成一条后台自动管线。
//
// 背景：任务中心原有两条手动路径——「扫描待办」（只读）与「执行全部待办」
// （扫描 → accept → 逐项执行 → 回读 → 自动领奖）。autorun 让后者按可配间隔
// 自己跑：无需人工点击，任务到点自动推进；进程重启后先补跑一轮当日漏跑的时点。
//
// 语义：
//   - 默认开启、间隔 2 小时；进程启动 90s 后先跑一轮（补重启期间漏掉的时点），
//     此后按间隔循环。面板可热改开关与间隔，改动经 wake 通道立即重排。
//   - 与手动队列共用 queueState：自动轮执行期间用户点「执行全部待办」会命中
//     「队列正在执行中」冲突分支，反之亦然——两者不会并发双开。
//   - 幂等：无待办时 startGrowthQueue 直返 started=false，只花一次扫描的上游
//     调用（与手动点一次「扫描待办」同量级）；上一轮还在跑时直接跳过本轮。
package panel

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"
)

// 自动执行器默认参数。间隔下限 5 分钟：账号数多时一轮「扫描 + 执行」本身就要
// 数分钟（队列内含真实对话与逐项节流），更密的间隔只会让下一轮永远追着上一轮跑。
const (
	autoTaskDefaultInterval = 2 * time.Hour
	autoTaskMinInterval     = 5 * time.Minute
	autoTaskFirstDelay      = 90 * time.Second
	autoTaskMaxInterval     = 24 * time.Hour
)

// autoTaskState 自动执行器的运行状态（字段均在 mu 下读写）。
type autoTaskState struct {
	mu       sync.Mutex
	enabled  bool
	interval time.Duration
	nextAt   time.Time

	lastAt      time.Time
	lastStarted bool
	lastSkipped bool
	lastTotal   int
	lastMessage string
	runs        int64

	// wake 非阻塞唤醒等待中的循环：开关/间隔热改后立即重排，不必睡满旧间隔。
	wake chan struct{}
}

// autoTaskStatus 自动执行器对外的状态快照（GET /panel/api/tasks/auto）。
type autoTaskStatus struct {
	Enabled         bool      `json:"enabled"`
	IntervalMinutes int       `json:"interval_minutes"`
	NextAt          time.Time `json:"next_at"`
	LastAt          time.Time `json:"last_at"`
	LastStarted     bool      `json:"last_started"`
	LastSkipped     bool      `json:"last_skipped"`
	LastTotal       int       `json:"last_total"`
	LastMessage     string    `json:"last_message,omitempty"`
	Runs            int64     `json:"runs"`
	QueueRunning    bool      `json:"queue_running"`
}

// autoTasks 惰性初始化自动执行器状态（默认开启、默认间隔）。
func (p *Panel) autoTasks() *autoTaskState {
	p.autoOnce.Do(func() {
		p.auto = &autoTaskState{
			enabled:  true,
			interval: autoTaskDefaultInterval,
			nextAt:   time.Now().Add(autoTaskFirstDelay),
			wake:     make(chan struct{}, 1),
		}
	})
	return p.auto
}

// poke 非阻塞唤醒等待中的循环（已有待处理信号则忽略，语义等价）。
func (s *autoTaskState) poke() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// status 锁内取一份状态快照。
func (s *autoTaskState) status() autoTaskStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	return autoTaskStatus{
		Enabled:         s.enabled,
		IntervalMinutes: int(s.interval / time.Minute),
		NextAt:          s.nextAt,
		LastAt:          s.lastAt,
		LastStarted:     s.lastStarted,
		LastSkipped:     s.lastSkipped,
		LastTotal:       s.lastTotal,
		LastMessage:     s.lastMessage,
		Runs:            s.runs,
	}
}

// StartAutoTasks 启动后台自动执行循环（阻塞在 ctx 取消前，需自行开 goroutine）。
// 应在 main 拿到可取消 ctx 后调用一次；未调用时自动执行器不运转让手动路径照旧。
func (p *Panel) StartAutoTasks(ctx context.Context) {
	st := p.autoTasks()
	snap := st.status()
	log.Printf("panel: 任务自动化已启动（开关 %v，间隔 %dm，首次 %s 后）",
		snap.Enabled, snap.IntervalMinutes, autoTaskFirstDelay)
	go func() {
		for {
			st.mu.Lock()
			enabled, next := st.enabled, st.nextAt
			st.mu.Unlock()
			if !enabled || next.IsZero() {
				// 关闭中：不空转，等热改唤醒（重新开启）或退出信号。
				select {
				case <-ctx.Done():
					return
				case <-st.wake:
				}
				continue
			}
			wait := time.Until(next)
			if wait < 0 {
				wait = 0
			}
			timer := time.NewTimer(wait)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-st.wake:
				timer.Stop() // 排程已变：回到循环顶重算
			case <-timer.C:
				p.runAutoTasksOnce()
				st.mu.Lock()
				if st.enabled {
					st.nextAt = time.Now().Add(st.interval)
				}
				st.mu.Unlock()
			}
		}
	}()
}

// runAutoTasksOnce 跑一轮自动任务：走「执行全部待办」同管线（扫描 + 执行，
// 账号间并发 1）。结果写回状态供面板展示；已在跑时跳过本轮。
func (p *Panel) runAutoTasksOnce() {
	st := p.autoTasks()
	if p.cfg.Pool == nil || p.cfg.Upstream == nil {
		// 未装配池/上游（测试或裁剪部署）：不发起任何调用，只记一轮空跑。
		st.mu.Lock()
		st.runs++
		st.lastAt = time.Now()
		st.lastMessage = "面板未装配账号池，跳过"
		st.mu.Unlock()
		return
	}
	started, total, seq, msg := p.startGrowthQueue(1, true)
	skipped := seq == -1 // 队列已被手动触发或上一轮占用
	st.mu.Lock()
	st.runs++
	st.lastAt = time.Now()
	st.lastStarted = started
	st.lastSkipped = skipped
	st.lastTotal = total
	st.lastMessage = msg
	st.mu.Unlock()
	switch {
	case skipped:
		log.Printf("panel: 自动任务跳过本轮（%s）", msg)
	case !started:
		log.Printf("panel: 自动任务无待办（%s）", msg)
	default:
		log.Printf("panel: 自动任务已启动，排队 %d 项", total)
	}
}

// autoTasksStatusHandler GET /panel/api/tasks/auto：自动执行状态 + 队列是否在跑。
func (p *Panel) autoTasksStatusHandler(w http.ResponseWriter, r *http.Request) {
	out := p.autoTasks().status()
	q := p.queue()
	q.mu.Lock()
	out.QueueRunning = q.running
	q.mu.Unlock()
	writeJSON(w, http.StatusOK, out)
}

// autoTasksConfigHandler POST /panel/api/tasks/auto：热改开关/间隔（内存态，重启
// 回落默认「开启」）。body 两字段都可选：{enabled?:bool, interval_minutes?:int}。
// 间隔夹取 [5, 1440] 分钟；改动后唤醒循环立即重排，返回最新状态。
func (p *Panel) autoTasksConfigHandler(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Enabled         *bool `json:"enabled"`
		IntervalMinutes int   `json:"interval_minutes"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body: "+err.Error())
		return
	}
	st := p.autoTasks()
	st.mu.Lock()
	if body.IntervalMinutes > 0 {
		d := time.Duration(body.IntervalMinutes) * time.Minute
		if d < autoTaskMinInterval {
			d = autoTaskMinInterval
		}
		if d > autoTaskMaxInterval {
			d = autoTaskMaxInterval
		}
		st.interval = d
		if st.enabled {
			st.nextAt = time.Now().Add(d) // 改间隔：按新间隔重排（不立刻触发）
		}
	}
	// 开关放在间隔之后：重新开启的「补跑一轮」优先于同请求里的改间隔——
	// 否则一次 POST 同时开开关+改间隔会把补跑重排到整个间隔之后。
	if body.Enabled != nil {
		reopen := *body.Enabled && !st.enabled
		st.enabled = *body.Enabled
		if reopen {
			st.nextAt = time.Now().Add(autoTaskFirstDelay) // 重新开启：先补跑一轮
		}
	}
	st.mu.Unlock()
	st.poke()
	out := st.status()
	q := p.queue()
	q.mu.Lock()
	out.QueueRunning = q.running
	q.mu.Unlock()
	log.Printf("panel: 任务自动化设置已更新（开关 %v，间隔 %dm）", out.Enabled, out.IntervalMinutes)
	writeJSON(w, http.StatusOK, out)
}

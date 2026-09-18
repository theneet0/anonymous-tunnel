package main

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Config struct {
	Mode          string            `json:"mode"`
	BindAddr      string            `json:"bind_addr,omitempty"`
	ServerAddr    string            `json:"server_addr,omitempty"`
	Token         string            `json:"token"`
	Transport     string            `json:"transport,omitempty"`
	CertFile      string            `json:"cert,omitempty"`
	KeyFile       string            `json:"key,omitempty"`
	BandwidthMbps float64           `json:"bandwidth_limit_mbps,omitempty"`
	Services      map[string]string `json:"services"`
}

const (
	tAuth   = 1
	tOpen   = 3
	tOpened = 4
	tData   = 5
	tClose  = 6
	tPing   = 7
	tPong   = 8
	tPad    = 9
)

const poolSize = 8

type Frame struct {
	Type   byte
	Stream uint32
	Data   []byte
}

func encodeFramePlain(f Frame) []byte {
	buf := make([]byte, 9+len(f.Data))
	buf[0] = f.Type
	binary.BigEndian.PutUint32(buf[1:5], f.Stream)
	binary.BigEndian.PutUint32(buf[5:9], uint32(len(f.Data)))
	copy(buf[9:], f.Data)
	return buf
}

func decodeFramePlain(buf []byte) (Frame, error) {
	if len(buf) < 9 {
		return Frame{}, errors.New("short frame")
	}
	length := binary.BigEndian.Uint32(buf[5:9])
	if len(buf) < 9+int(length) {
		return Frame{}, errors.New("bad frame length")
	}
	return Frame{Type: buf[0], Stream: binary.BigEndian.Uint32(buf[1:5]), Data: buf[9 : 9+int(length)]}, nil
}

func hkdfExtract(salt, ikm []byte) []byte {
	mac := hmac.New(sha256.New, salt)
	mac.Write(ikm)
	return mac.Sum(nil)
}

func hkdfExpand(prk []byte, info string, length int) []byte {
	var out []byte
	var t []byte
	counter := byte(1)
	for len(out) < length {
		mac := hmac.New(sha256.New, prk)
		mac.Write(t)
		mac.Write([]byte(info))
		mac.Write([]byte{counter})
		t = mac.Sum(nil)
		out = append(out, t...)
		counter++
	}
	return out[:length]
}

func deriveAEADKeys(shared []byte, token string) ([]byte, []byte) {
	prk := hkdfExtract([]byte(token), shared)
	c2s := hkdfExpand(prk, "c2s", 32)
	s2c := hkdfExpand(prk, "s2c", 32)
	return c2s, s2c
}

func newAEAD(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

type secureChannel struct {
	conn     net.Conn
	sendAEAD cipher.AEAD
	recvAEAD cipher.AEAD
	sendSeq  uint64
	recvSeq  uint64
	writeMu  sync.Mutex
	br       *bufio.Reader
}

func (sc *secureChannel) writeFrame(f Frame) error {
	plain := encodeFramePlain(f)
	sc.writeMu.Lock()
	defer sc.writeMu.Unlock()
	nonce := make([]byte, 12)
	binary.BigEndian.PutUint64(nonce[4:], sc.sendSeq)
	sc.sendSeq++
	sealed := sc.sendAEAD.Seal(nil, nonce, plain, nil)
	lenBuf := make([]byte, 4)
	binary.BigEndian.PutUint32(lenBuf, uint32(len(sealed)))
	full := append(lenBuf, sealed...)
	_, err := sc.conn.Write(full)
	return err
}

func (sc *secureChannel) readFrame() (Frame, error) {
	lenBuf := make([]byte, 4)
	if _, err := io.ReadFull(sc.br, lenBuf); err != nil {
		return Frame{}, err
	}
	length := binary.BigEndian.Uint32(lenBuf)
	if length > 1<<20 {
		return Frame{}, errors.New("frame too large")
	}
	sealed := make([]byte, length)
	if _, err := io.ReadFull(sc.br, sealed); err != nil {
		return Frame{}, err
	}
	nonce := make([]byte, 12)
	binary.BigEndian.PutUint64(nonce[4:], sc.recvSeq)
	sc.recvSeq++
	plain, err := sc.recvAEAD.Open(nil, nonce, sealed, nil)
	if err != nil {
		return Frame{}, err
	}
	return decodeFramePlain(plain)
}

func (sc *secureChannel) Close() error {
	return sc.conn.Close()
}

func newSecureChannelClient(conn net.Conn, token string) (*secureChannel, error) {
	curve := ecdh.X25519()
	priv, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	pub := priv.PublicKey().Bytes()
	if _, err := conn.Write(pub); err != nil {
		return nil, err
	}
	peerBuf := make([]byte, 32)
	if _, err := io.ReadFull(conn, peerBuf); err != nil {
		return nil, err
	}
	peerPub, err := curve.NewPublicKey(peerBuf)
	if err != nil {
		return nil, err
	}
	shared, err := priv.ECDH(peerPub)
	if err != nil {
		return nil, err
	}
	c2s, s2c := deriveAEADKeys(shared, token)
	sendAEAD, err := newAEAD(c2s)
	if err != nil {
		return nil, err
	}
	recvAEAD, err := newAEAD(s2c)
	if err != nil {
		return nil, err
	}
	return &secureChannel{conn: conn, sendAEAD: sendAEAD, recvAEAD: recvAEAD, br: bufio.NewReaderSize(conn, 65536)}, nil
}

func newSecureChannelServer(conn net.Conn, token string) (*secureChannel, error) {
	curve := ecdh.X25519()
	peerBuf := make([]byte, 32)
	if _, err := io.ReadFull(conn, peerBuf); err != nil {
		return nil, err
	}
	peerPub, err := curve.NewPublicKey(peerBuf)
	if err != nil {
		return nil, err
	}
	priv, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	if _, err := conn.Write(priv.PublicKey().Bytes()); err != nil {
		return nil, err
	}
	shared, err := priv.ECDH(peerPub)
	if err != nil {
		return nil, err
	}
	c2s, s2c := deriveAEADKeys(shared, token)
	sendAEAD, err := newAEAD(s2c)
	if err != nil {
		return nil, err
	}
	recvAEAD, err := newAEAD(c2s)
	if err != nil {
		return nil, err
	}
	return &secureChannel{conn: conn, sendAEAD: sendAEAD, recvAEAD: recvAEAD, br: bufio.NewReaderSize(conn, 65536)}, nil
}

var bufPool = sync.Pool{
	New: func() interface{} {
		buf := make([]byte, 32*1024)
		return &buf
	},
}

type rateLimiter struct {
	mu         sync.Mutex
	tokens     float64
	maxTokens  float64
	refillRate float64
	lastRefill time.Time
}

func newRateLimiter(bytesPerSec float64) *rateLimiter {
	return &rateLimiter{
		tokens:     bytesPerSec,
		maxTokens:  bytesPerSec,
		refillRate: bytesPerSec,
		lastRefill: time.Now(),
	}
}

func (r *rateLimiter) wait(n int) {
	if r == nil || n <= 0 {
		return
	}
	for {
		r.mu.Lock()
		now := time.Now()
		elapsed := now.Sub(r.lastRefill).Seconds()
		r.tokens += elapsed * r.refillRate
		if r.tokens > r.maxTokens {
			r.tokens = r.maxTokens
		}
		r.lastRefill = now
		if r.tokens >= float64(n) {
			r.tokens -= float64(n)
			r.mu.Unlock()
			return
		}
		needed := float64(n) - r.tokens
		waitSec := needed / r.refillRate
		r.mu.Unlock()
		time.Sleep(time.Duration(waitSec * float64(time.Second)))
	}
}

var txLimiter *rateLimiter
var rxLimiter *rateLimiter

func setupRateLimiters(mbps float64) {
	if mbps <= 0 {
		return
	}
	bytesPerSec := mbps * 1000000 / 8
	txLimiter = newRateLimiter(bytesPerSec)
	rxLimiter = newRateLimiter(bytesPerSec)
}

type throttledWriter struct {
	w  io.Writer
	rl *rateLimiter
}

func (t *throttledWriter) Write(p []byte) (int, error) {
	t.rl.wait(len(p))
	return t.w.Write(p)
}

func setNoDelay(conn net.Conn) {
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
}

func normalizeTransport(t string) string {
	if t == "" {
		return "tcp_mux"
	}
	return t
}

func isClassic(t string) bool {
	switch t {
	case "tcp", "ws", "wss":
		return true
	}
	return false
}

func randInt(max int) int {
	b := make([]byte, 2)
	rand.Read(b)
	v := int(binary.BigEndian.Uint16(b))
	if max <= 0 {
		return 0
	}
	return v % max
}

func writeStealthPrefix(conn net.Conn, innerLen int) error {
	header := make([]byte, 5)
	header[0] = 0x16
	header[1] = 0x03
	header[2] = 0x03
	binary.BigEndian.PutUint16(header[3:5], uint16(innerLen))
	_, err := conn.Write(header)
	return err
}

func readStealthPrefix(conn net.Conn) error {
	header := make([]byte, 5)
	_, err := io.ReadFull(conn, header)
	return err
}

func startChaff(sendFn func(Frame) error, doneCh <-chan struct{}) {
	go func() {
		for {
			wait := time.Duration(3000+randInt(5000)) * time.Millisecond
			select {
			case <-time.After(wait):
				n := 16 + randInt(200)
				junk := make([]byte, n)
				rand.Read(junk)
				if sendFn(Frame{Type: tPad, Data: junk}) != nil {
					return
				}
			case <-doneCh:
				return
			}
		}
	}()
}

func sendShaped(p *pool, id uint32, data []byte, size int) error {
	off := 0
	for off < len(data) {
		chunkSize := 200 + randInt(600)
		end := off + chunkSize
		if end > len(data) {
			end = len(data)
		}
		chunk := make([]byte, end-off)
		copy(chunk, data[off:end])
		if err := p.send(Frame{Type: tData, Stream: id, Data: chunk}, size); err != nil {
			return err
		}
		off = end
		if off < len(data) {
			time.Sleep(time.Duration(1+randInt(8)) * time.Millisecond)
		}
	}
	return nil
}

type wsConn struct {
	net.Conn
	br       *bufio.Reader
	isClient bool
	leftover []byte
}

func readWSFrame(br *bufio.Reader) (byte, []byte, error) {
	head := make([]byte, 2)
	if _, err := io.ReadFull(br, head); err != nil {
		return 0, nil, err
	}
	opcode := head[0] & 0x0f
	masked := head[1]&0x80 != 0
	length := uint64(head[1] & 0x7f)
	if length == 126 {
		ext := make([]byte, 2)
		if _, err := io.ReadFull(br, ext); err != nil {
			return 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(ext))
	} else if length == 127 {
		ext := make([]byte, 8)
		if _, err := io.ReadFull(br, ext); err != nil {
			return 0, nil, err
		}
		length = binary.BigEndian.Uint64(ext)
	}
	var maskKey [4]byte
	if masked {
		if _, err := io.ReadFull(br, maskKey[:]); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, length)
	if length > 0 {
		if _, err := io.ReadFull(br, payload); err != nil {
			return 0, nil, err
		}
	}
	if masked {
		for i := range payload {
			payload[i] ^= maskKey[i%4]
		}
	}
	return opcode, payload, nil
}

func writeWSFrame(w io.Writer, opcode byte, payload []byte, mask bool) error {
	var header []byte
	header = append(header, 0x80|opcode)
	length := len(payload)
	if length < 126 {
		b1 := byte(length)
		if mask {
			b1 |= 0x80
		}
		header = append(header, b1)
	} else if length <= 65535 {
		b1 := byte(126)
		if mask {
			b1 |= 0x80
		}
		header = append(header, b1)
		ext := make([]byte, 2)
		binary.BigEndian.PutUint16(ext, uint16(length))
		header = append(header, ext...)
	} else {
		b1 := byte(127)
		if mask {
			b1 |= 0x80
		}
		header = append(header, b1)
		ext := make([]byte, 8)
		binary.BigEndian.PutUint64(ext, uint64(length))
		header = append(header, ext...)
	}
	if mask {
		var maskKey [4]byte
		rand.Read(maskKey[:])
		header = append(header, maskKey[:]...)
		masked := make([]byte, length)
		for i := 0; i < length; i++ {
			masked[i] = payload[i] ^ maskKey[i%4]
		}
		if _, err := w.Write(header); err != nil {
			return err
		}
		_, err := w.Write(masked)
		return err
	}
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func (c *wsConn) Read(p []byte) (int, error) {
	for len(c.leftover) == 0 {
		op, payload, err := readWSFrame(c.br)
		if err != nil {
			return 0, err
		}
		if op == 8 {
			return 0, io.EOF
		}
		if op == 2 || op == 1 {
			c.leftover = payload
		}
	}
	n := copy(p, c.leftover)
	c.leftover = c.leftover[n:]
	return n, nil
}

func (c *wsConn) Write(p []byte) (int, error) {
	if err := writeWSFrame(c.Conn, 2, p, c.isClient); err != nil {
		return 0, err
	}
	return len(p), nil
}

func wsDial(addr string, useTLS bool) (net.Conn, error) {
	if useTLS {
		raw, err := net.Dial("tcp", addr)
		if err != nil {
			return nil, err
		}
		setNoDelay(raw)
		tlsConn := tls.Client(raw, &tls.Config{InsecureSkipVerify: true})
		if err := tlsConn.Handshake(); err != nil {
			log.Printf("[wss] tls handshake failed: %v", err)
			raw.Close()
			return nil, err
		}
		return wsHandshakeClient(tlsConn, addr)
	}
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	setNoDelay(conn)
	return wsHandshakeClient(conn, addr)
}

func wsHandshakeClient(conn net.Conn, addr string) (net.Conn, error) {
	keyBytes := make([]byte, 16)
	rand.Read(keyBytes)
	key := base64.StdEncoding.EncodeToString(keyBytes)
	req := "GET / HTTP/1.1\r\nHost: " + addr + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		conn.Close()
		return nil, err
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		log.Printf("[ws] failed to read handshake response: %v", err)
		conn.Close()
		return nil, err
	}
	if resp.StatusCode != 101 {
		log.Printf("[ws] handshake rejected: unexpected status %d", resp.StatusCode)
		conn.Close()
		return nil, errors.New("websocket handshake failed")
	}
	return &wsConn{Conn: conn, br: br, isClient: true}, nil
}

type wsListener struct {
	net.Listener
	tlsConfig *tls.Config
}

func (l *wsListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	setNoDelay(conn)
	var wrapped net.Conn = conn
	if l.tlsConfig != nil {
		tlsConn := tls.Server(conn, l.tlsConfig)
		if err := tlsConn.Handshake(); err != nil {
			log.Printf("[wss] tls handshake failed with %v: %v", conn.RemoteAddr(), err)
			conn.Close()
			return nil, err
		}
		wrapped = tlsConn
	}
	br := bufio.NewReader(wrapped)
	req, err := http.ReadRequest(br)
	if err != nil {
		log.Printf("[ws] failed to parse upgrade request from %v: %v", conn.RemoteAddr(), err)
		wrapped.Close()
		return nil, err
	}
	wsKey := req.Header.Get("Sec-WebSocket-Key")
	h := sha1.New()
	h.Write([]byte(wsKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	accept := base64.StdEncoding.EncodeToString(h.Sum(nil))
	resp := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"
	if _, err := wrapped.Write([]byte(resp)); err != nil {
		wrapped.Close()
		return nil, err
	}
	return &wsConn{Conn: wrapped, br: br, isClient: false}, nil
}

func wsListen(addr string, useTLS bool, certFile, keyFile string) (net.Listener, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	l := &wsListener{Listener: ln}
	if useTLS {
		cert, cerr := tls.LoadX509KeyPair(certFile, keyFile)
		if cerr != nil {
			return nil, cerr
		}
		l.tlsConfig = &tls.Config{Certificates: []tls.Certificate{cert}}
	}
	return l, nil
}

const udpMaxPayload = 1200

const (
	upData   = 1
	upParity = 2
	upAck    = 3
)

func encodeUDPPacket(t byte, seq uint32, groupID uint16, idxOrCount byte, payload []byte) []byte {
	buf := make([]byte, 10+len(payload))
	buf[0] = t
	binary.BigEndian.PutUint32(buf[1:5], seq)
	binary.BigEndian.PutUint16(buf[5:7], groupID)
	buf[7] = idxOrCount
	binary.BigEndian.PutUint16(buf[8:10], uint16(len(payload)))
	copy(buf[10:], payload)
	return buf
}

func decodeUDPPacket(pkt []byte) (byte, uint32, uint16, byte, []byte, bool) {
	if len(pkt) < 10 {
		return 0, 0, 0, 0, nil, false
	}
	t := pkt[0]
	seq := binary.BigEndian.Uint32(pkt[1:5])
	groupID := binary.BigEndian.Uint16(pkt[5:7])
	idxOrCount := pkt[7]
	length := binary.BigEndian.Uint16(pkt[8:10])
	if len(pkt) < 10+int(length) {
		return 0, 0, 0, 0, nil, false
	}
	payload := pkt[10 : 10+int(length)]
	return t, seq, groupID, idxOrCount, payload, true
}

type pendingPkt struct {
	data  []byte
	sent  time.Time
	tries int
}

type recvGroup struct {
	data        [4][]byte
	present     [4]bool
	baseSeq     uint32
	haveBase    bool
	parity      []byte
	hasParity   bool
	memberCount int
}

type udpSession struct {
	sendFunc   func([]byte) error
	remoteAddr net.Addr

	seqCounter uint32

	pendingMu sync.Mutex
	pending   map[uint32]*pendingPkt

	groupMu     sync.Mutex
	curGroupID  uint16
	curGroup    [4][]byte
	curGroupLen int
	groupStart  time.Time

	recvMu      sync.Mutex
	recvGroups  map[uint16]*recvGroup
	nextDeliver uint32
	deliverBuf  map[uint32][]byte

	deliverCh    chan []byte
	readLeftover []byte

	closed    chan struct{}
	closeOnce sync.Once

	listener   *udpListener
	sessionKey string
}

func newUDPSessionBase() *udpSession {
	return &udpSession{
		pending:    make(map[uint32]*pendingPkt),
		recvGroups: make(map[uint16]*recvGroup),
		deliverBuf: make(map[uint32][]byte),
		deliverCh:  make(chan []byte, 256),
		closed:     make(chan struct{}),
		groupStart: time.Now(),
	}
}

func newClientUDPSession(conn *net.UDPConn) *udpSession {
	s := newUDPSessionBase()
	s.sendFunc = func(b []byte) error {
		_, err := conn.Write(b)
		return err
	}
	go s.flusher()
	go s.resender()
	go func() {
		buf := make([]byte, 2048)
		for {
			n, err := conn.Read(buf)
			if err != nil {
				s.Close()
				return
			}
			pkt := make([]byte, n)
			copy(pkt, buf[:n])
			s.handlePacket(pkt)
		}
	}()
	return s
}

func newServerUDPSession(conn *net.UDPConn, remote *net.UDPAddr) *udpSession {
	s := newUDPSessionBase()
	s.remoteAddr = remote
	s.sendFunc = func(b []byte) error {
		_, err := conn.WriteToUDP(b, remote)
		return err
	}
	go s.flusher()
	go s.resender()
	return s
}

func (s *udpSession) Read(p []byte) (int, error) {
	if len(s.readLeftover) == 0 {
		select {
		case data, ok := <-s.deliverCh:
			if !ok {
				return 0, io.EOF
			}
			s.readLeftover = data
		case <-s.closed:
			return 0, io.EOF
		}
	}
	n := copy(p, s.readLeftover)
	s.readLeftover = s.readLeftover[n:]
	return n, nil
}

func (s *udpSession) writeChunk(payload []byte) {
	seq := atomic.AddUint32(&s.seqCounter, 1) - 1
	s.groupMu.Lock()
	idx := s.curGroupLen
	cp := append([]byte{}, payload...)
	s.curGroup[idx] = cp
	s.curGroupLen++
	groupID := s.curGroupID
	full := s.curGroupLen == 4
	var toParity [][]byte
	if full {
		toParity = append(toParity, s.curGroup[:]...)
		s.curGroupID++
		s.curGroupLen = 0
		s.curGroup = [4][]byte{}
		s.groupStart = time.Now()
	}
	s.groupMu.Unlock()

	pkt := encodeUDPPacket(upData, seq, groupID, byte(idx), payload)
	s.pendingMu.Lock()
	s.pending[seq] = &pendingPkt{data: pkt, sent: time.Now()}
	s.pendingMu.Unlock()
	s.sendFunc(pkt)

	if full {
		s.emitParity(groupID, toParity)
	}
}

func (s *udpSession) emitParity(groupID uint16, members [][]byte) {
	parity := make([]byte, udpMaxPayload+2)
	for _, m := range members {
		lp := make([]byte, udpMaxPayload+2)
		binary.BigEndian.PutUint16(lp[0:2], uint16(len(m)))
		copy(lp[2:], m)
		for i := range parity {
			parity[i] ^= lp[i]
		}
	}
	pkt := encodeUDPPacket(upParity, 0, groupID, byte(len(members)), parity)
	s.sendFunc(pkt)
}

func (s *udpSession) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	off := 0
	for off < len(p) {
		end := off + udpMaxPayload
		if end > len(p) {
			end = len(p)
		}
		s.writeChunk(p[off:end])
		off = end
	}
	return len(p), nil
}

func (s *udpSession) Close() error {
	s.closeOnce.Do(func() {
		close(s.closed)
		if s.listener != nil {
			s.listener.mu.Lock()
			if s.listener.sessions[s.sessionKey] == s {
				delete(s.listener.sessions, s.sessionKey)
			}
			s.listener.mu.Unlock()
		}
	})
	return nil
}

func (s *udpSession) LocalAddr() net.Addr                { return nil }
func (s *udpSession) RemoteAddr() net.Addr               { return s.remoteAddr }
func (s *udpSession) SetDeadline(t time.Time) error      { return nil }
func (s *udpSession) SetReadDeadline(t time.Time) error  { return nil }
func (s *udpSession) SetWriteDeadline(t time.Time) error { return nil }

func (s *udpSession) flusher() {
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			s.groupMu.Lock()
			if s.curGroupLen > 0 && time.Since(s.groupStart) > 15*time.Millisecond {
				members := append([][]byte{}, s.curGroup[:s.curGroupLen]...)
				groupID := s.curGroupID
				s.curGroupID++
				s.curGroupLen = 0
				s.curGroup = [4][]byte{}
				s.groupStart = time.Now()
				s.groupMu.Unlock()
				s.emitParity(groupID, members)
			} else {
				s.groupMu.Unlock()
			}
		case <-s.closed:
			return
		}
	}
}

func (s *udpSession) resender() {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			now := time.Now()
			s.pendingMu.Lock()
			for seq, p := range s.pending {
				if now.Sub(p.sent) > 320*time.Millisecond {
					p.tries++
					p.sent = now
					if p.tries > 30 {
						delete(s.pending, seq)
						continue
					}
					s.sendFunc(p.data)
				}
			}
			s.pendingMu.Unlock()
		case <-s.closed:
			return
		}
	}
}

func (s *udpSession) handlePacket(pkt []byte) {
	t, seq, groupID, idxOrCount, payload, ok := decodeUDPPacket(pkt)
	if !ok {
		return
	}
	switch t {
	case upData:
		ackPkt := encodeUDPPacket(upAck, seq, 0, 0, nil)
		s.sendFunc(ackPkt)
		s.storeRecvData(groupID, idxOrCount, seq, payload)
	case upParity:
		s.storeRecvParity(groupID, idxOrCount, payload)
	case upAck:
		s.pendingMu.Lock()
		delete(s.pending, seq)
		s.pendingMu.Unlock()
	}
}

func (s *udpSession) getGroup(groupID uint16) *recvGroup {
	s.recvMu.Lock()
	g, ok := s.recvGroups[groupID]
	if !ok {
		g = &recvGroup{}
		s.recvGroups[groupID] = g
	}
	s.recvMu.Unlock()
	return g
}

func (s *udpSession) storeRecvData(groupID uint16, idx byte, seq uint32, payload []byte) {
	g := s.getGroup(groupID)
	s.recvMu.Lock()
	if int(idx) < 4 && !g.present[idx] {
		g.present[idx] = true
		cp := append([]byte{}, payload...)
		g.data[idx] = cp
		g.baseSeq = seq - uint32(idx)
		g.haveBase = true
	}
	s.recvMu.Unlock()
	s.deliverPayload(seq, payload)
	s.tryReconstruct(groupID, g)
	s.cleanupGroup(groupID, g)
}

func (s *udpSession) storeRecvParity(groupID uint16, memberCount byte, payload []byte) {
	g := s.getGroup(groupID)
	s.recvMu.Lock()
	g.parity = append([]byte{}, payload...)
	g.hasParity = true
	g.memberCount = int(memberCount)
	s.recvMu.Unlock()
	s.tryReconstruct(groupID, g)
	s.cleanupGroup(groupID, g)
}

func (s *udpSession) tryReconstruct(groupID uint16, g *recvGroup) {
	s.recvMu.Lock()
	if !g.hasParity || !g.haveBase {
		s.recvMu.Unlock()
		return
	}
	missing := -1
	count := 0
	limit := g.memberCount
	if limit == 0 || limit > 4 {
		s.recvMu.Unlock()
		return
	}
	for i := 0; i < limit; i++ {
		if g.present[i] {
			count++
		} else {
			missing = i
		}
	}
	if count == limit || count != limit-1 || missing == -1 {
		s.recvMu.Unlock()
		return
	}
	lp := make([]byte, udpMaxPayload+2)
	copy(lp, g.parity)
	for i := 0; i < limit; i++ {
		if i == missing {
			continue
		}
		m := make([]byte, udpMaxPayload+2)
		binary.BigEndian.PutUint16(m[0:2], uint16(len(g.data[i])))
		copy(m[2:], g.data[i])
		for j := range lp {
			lp[j] ^= m[j]
		}
	}
	length := binary.BigEndian.Uint16(lp[0:2])
	if int(length) > udpMaxPayload {
		s.recvMu.Unlock()
		return
	}
	recovered := append([]byte{}, lp[2:2+int(length)]...)
	g.data[missing] = recovered
	g.present[missing] = true
	seq := g.baseSeq + uint32(missing)
	s.recvMu.Unlock()
	s.deliverPayload(seq, recovered)
}

func (s *udpSession) cleanupGroup(groupID uint16, g *recvGroup) {
	s.recvMu.Lock()
	defer s.recvMu.Unlock()
	limit := g.memberCount
	if limit == 0 {
		return
	}
	full := true
	for i := 0; i < limit; i++ {
		if !g.present[i] {
			full = false
			break
		}
	}
	if full {
		delete(s.recvGroups, groupID)
	}
}

func (s *udpSession) deliverPayload(seq uint32, payload []byte) {
	s.recvMu.Lock()
	if _, exists := s.deliverBuf[seq]; exists {
		s.recvMu.Unlock()
		return
	}
	cp := append([]byte{}, payload...)
	s.deliverBuf[seq] = cp
	for {
		p, ok := s.deliverBuf[s.nextDeliver]
		if !ok {
			break
		}
		delete(s.deliverBuf, s.nextDeliver)
		s.nextDeliver++
		s.recvMu.Unlock()
		select {
		case s.deliverCh <- p:
		case <-s.closed:
			return
		}
		s.recvMu.Lock()
	}
	s.recvMu.Unlock()
}

type udpListener struct {
	conn     *net.UDPConn
	acceptCh chan net.Conn
	sessions map[string]*udpSession
	mu       sync.Mutex
}

func (l *udpListener) Accept() (net.Conn, error) {
	c, ok := <-l.acceptCh
	if !ok {
		return nil, errors.New("listener closed")
	}
	return c, nil
}

func (l *udpListener) Close() error {
	return l.conn.Close()
}

func (l *udpListener) Addr() net.Addr {
	return l.conn.LocalAddr()
}

func (l *udpListener) readLoop() {
	buf := make([]byte, 2048)
	for {
		n, addr, err := l.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		key := addr.String()
		l.mu.Lock()
		sess, ok := l.sessions[key]
		if !ok {
			sess = newServerUDPSession(l.conn, addr)
			sess.listener = l
			sess.sessionKey = key
			l.sessions[key] = sess
			l.mu.Unlock()
			l.acceptCh <- sess
		} else {
			l.mu.Unlock()
		}
		sess.handlePacket(pkt)
	}
}

func udpListen(addr string) (net.Listener, error) {
	laddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP("udp", laddr)
	if err != nil {
		return nil, err
	}
	l := &udpListener{conn: conn, acceptCh: make(chan net.Conn, 8), sessions: make(map[string]*udpSession)}
	go l.readLoop()
	return l, nil
}

func udpDial(addr string) (net.Conn, error) {
	raddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, err
	}
	conn, err := net.DialUDP("udp", nil, raddr)
	if err != nil {
		return nil, err
	}
	sess := newClientUDPSession(conn)
	sess.remoteAddr = raddr
	return sess, nil
}

func dialTransport(cfg Config) (net.Conn, error) {
	t := normalizeTransport(cfg.Transport)
	switch t {
	case "tcp", "tcp_mux", "tcp_stealth", "tcp_pck":
		conn, err := net.Dial("tcp", cfg.ServerAddr)
		if err != nil {
			return nil, err
		}
		setNoDelay(conn)
		return conn, nil
	case "ws", "ws_mux":
		return wsDial(cfg.ServerAddr, false)
	case "wss", "wss_mux":
		return wsDial(cfg.ServerAddr, true)
	case "udp_fec":
		return udpDial(cfg.ServerAddr)
	default:
		return nil, errors.New("unknown transport")
	}
}

func listenTransport(cfg Config) (net.Listener, error) {
	t := normalizeTransport(cfg.Transport)
	switch t {
	case "tcp", "tcp_mux", "tcp_stealth", "tcp_pck":
		return net.Listen("tcp", cfg.BindAddr)
	case "ws", "ws_mux":
		return wsListen(cfg.BindAddr, false, "", "")
	case "wss", "wss_mux":
		return wsListen(cfg.BindAddr, true, cfg.CertFile, cfg.KeyFile)
	case "udp_fec":
		return udpListen(cfg.BindAddr)
	default:
		return nil, errors.New("unknown transport")
	}
}

func effectivePoolSize(transport string) int {
	return 1
}

var globalNextStreamID uint32

var totalRxBytes uint64
var totalTxBytes uint64

func addRxBytes(n int) {
	if n > 0 {
		atomic.AddUint64(&totalRxBytes, uint64(n))
	}
}

func addTxBytes(n int) {
	if n > 0 {
		atomic.AddUint64(&totalTxBytes, uint64(n))
	}
}

func loadExistingStats(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var s struct {
		Rx uint64 `json:"rx"`
		Tx uint64 `json:"tx"`
	}
	if err := json.Unmarshal(data, &s); err != nil {
		return
	}
	atomic.StoreUint64(&totalRxBytes, s.Rx)
	atomic.StoreUint64(&totalTxBytes, s.Tx)
}

func statsWriter(path string) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		rx := atomic.LoadUint64(&totalRxBytes)
		tx := atomic.LoadUint64(&totalTxBytes)
		data, err := json.Marshal(map[string]interface{}{
			"rx":      rx,
			"tx":      tx,
			"updated": time.Now().Unix(),
		})
		if err != nil {
			continue
		}
		tmpPath := path + ".tmp"
		if err := os.WriteFile(tmpPath, data, 0644); err != nil {
			continue
		}
		os.Rename(tmpPath, path)
	}
}

type pool struct {
	conns     [poolSize]*secureChannel
	mu        sync.RWMutex
	streams   map[uint32]net.Conn
	streamsMu sync.Mutex
}

func (p *pool) get(idx int) *secureChannel {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.conns[idx]
}

func (p *pool) set(idx int, sc *secureChannel) {
	p.mu.Lock()
	p.conns[idx] = sc
	p.mu.Unlock()
}

func (p *pool) allDead() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	for _, c := range p.conns {
		if c != nil {
			return false
		}
	}
	return true
}

func (p *pool) send(f Frame, size int) error {
	idx := 0
	if (f.Type == tData || f.Type == tClose) && size > 1 {
		idx = int(f.Stream % uint32(size))
	}
	sc := p.get(idx)
	if sc == nil {
		return errors.New("no connection available")
	}
	return sc.writeFrame(f)
}

func pipeBoth(a, b net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		var w io.Writer = a
		if rxLimiter != nil {
			w = &throttledWriter{w: a, rl: rxLimiter}
		}
		n, _ := io.Copy(w, b)
		addRxBytes(int(n))
		done <- struct{}{}
	}()
	go func() {
		var w io.Writer = b
		if txLimiter != nil {
			w = &throttledWriter{w: b, rl: txLimiter}
		}
		n, _ := io.Copy(w, b)
		addTxBytes(int(n))
		done <- struct{}{}
	}()
	<-done
	a.Close()
	b.Close()
	<-done
}

func pumpToPool(p *pool, id uint32, conn net.Conn, pck bool, size int) {
	for {
		bufp := bufPool.Get().(*[]byte)
		buf := *bufp
		n, err := conn.Read(buf)
		if n > 0 {
			addTxBytes(n)
			txLimiter.wait(n)
			var sendErr error
			if pck {
				sendErr = sendShaped(p, id, buf[:n], size)
			} else {
				sendErr = p.send(Frame{Type: tData, Stream: id, Data: buf[:n]}, size)
			}
			bufPool.Put(bufp)
			if sendErr != nil {
				log.Printf("[stream %d] failed to forward data over the tunnel: %v", id, sendErr)
				break
			}
		} else {
			bufPool.Put(bufp)
		}
		if err != nil {
			if err != io.EOF {
				log.Printf("[stream %d] local read error: %v", id, err)
			}
			break
		}
	}
	p.send(Frame{Type: tClose, Stream: id}, size)
	p.streamsMu.Lock()
	delete(p.streams, id)
	p.streamsMu.Unlock()
	conn.Close()
}

type serverShared struct {
	sessionMu    sync.Mutex
	session      *serverSession
	pendingBinds map[uint32]net.Conn
	bindMu       sync.Mutex
}

type serverSession struct {
	cfg       Config
	pool      *pool
	listeners []net.Listener
	srv       *serverShared
	poolSize  int
	closed    chan struct{}
	closeOnce sync.Once
}

func expirePendingBind(srv *serverShared, id uint32) {
	time.Sleep(10 * time.Second)
	srv.bindMu.Lock()
	vconn, ok := srv.pendingBinds[id]
	if ok {
		delete(srv.pendingBinds, id)
	}
	srv.bindMu.Unlock()
	if ok {
		log.Printf("[server] stream %d: no data connection arrived within 10s, dropping pending visitor", id)
		vconn.Close()
	}
}

func newServerSession(cfg Config, srv *serverShared) *serverSession {
	transport := normalizeTransport(cfg.Transport)
	classic := isClassic(transport)
	ps := effectivePoolSize(transport)
	pck := transport == "tcp_pck"
	log.Printf("[server] starting new session (transport=%s, pool size=%d)", transport, ps)
	sess := &serverSession{
		cfg:      cfg,
		pool:     &pool{streams: make(map[uint32]net.Conn)},
		srv:      srv,
		poolSize: ps,
		closed:   make(chan struct{}),
	}

	for name, addr := range cfg.Services {
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			log.Printf("[server] failed to listen on %s for service %q: %v", addr, name, err)
			continue
		}
		sess.listeners = append(sess.listeners, ln)
		go func(name string, ln net.Listener) {
			for {
				vconn, err := ln.Accept()
				if err != nil {
					return
				}
				setNoDelay(vconn)
				id := atomic.AddUint32(&globalNextStreamID, 1)
				if classic {
					srv.bindMu.Lock()
					srv.pendingBinds[id] = vconn
					srv.bindMu.Unlock()
					if sess.pool.send(Frame{Type: tOpen, Stream: id, Data: []byte(name)}, sess.poolSize) != nil {
						srv.bindMu.Lock()
						delete(srv.pendingBinds, id)
						srv.bindMu.Unlock()
						vconn.Close()
						continue
					}
					go expirePendingBind(srv, id)
				} else {
					sess.pool.streamsMu.Lock()
					sess.pool.streams[id] = vconn
					sess.pool.streamsMu.Unlock()
					if sess.pool.send(Frame{Type: tOpen, Stream: id, Data: []byte(name)}, sess.poolSize) != nil {
						vconn.Close()
						sess.pool.streamsMu.Lock()
						delete(sess.pool.streams, id)
						sess.pool.streamsMu.Unlock()
						continue
					}
					go pumpToPool(sess.pool, id, vconn, pck, sess.poolSize)
				}
			}
		}(name, ln)
	}

	go sess.watchdog()
	return sess
}

func (sess *serverSession) watchdog() {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	var deadSince time.Time
	for {
		select {
		case <-ticker.C:
			if sess.pool.allDead() {
				if deadSince.IsZero() {
					deadSince = time.Now()
				} else if time.Since(deadSince) > 10*time.Second {
					sess.teardown()
					return
				}
			} else {
				deadSince = time.Time{}
			}
		case <-sess.closed:
			return
		}
	}
}

func (sess *serverSession) teardown() {
	log.Printf("[server] session torn down: all pool connections have been dead for 30s")
	sess.closeOnce.Do(func() {
		close(sess.closed)
	})
	for _, ln := range sess.listeners {
		ln.Close()
	}
	sess.pool.streamsMu.Lock()
	for id, c := range sess.pool.streams {
		c.Close()
		delete(sess.pool.streams, id)
	}
	sess.pool.streamsMu.Unlock()
	sess.srv.sessionMu.Lock()
	if sess.srv.session == sess {
		sess.srv.session = nil
	}
	sess.srv.sessionMu.Unlock()
}

func attachPoolConn(cfg Config, srv *serverShared, idx int, sc *secureChannel) {
	srv.sessionMu.Lock()
	sess := srv.session
	if sess == nil {
		if idx != 0 {
			srv.sessionMu.Unlock()
			sc.Close()
			return
		}
		sess = newServerSession(cfg, srv)
		srv.session = sess
	}
	sess.pool.set(idx, sc)
	srv.sessionMu.Unlock()

	serverPoolReadLoop(sc, idx, cfg, sess)
}

func serverPoolReadLoop(sc *secureChannel, idx int, cfg Config, sess *serverSession) {
	transport := normalizeTransport(cfg.Transport)
	var lastPong int64
	atomic.StoreInt64(&lastPong, time.Now().UnixNano())
	pingTicker := time.NewTicker(3 * time.Second)
	defer pingTicker.Stop()
	pingDone := make(chan struct{})
	go func() {
		for {
			select {
			case <-pingTicker.C:
				if time.Since(time.Unix(0, atomic.LoadInt64(&lastPong))) > 9*time.Second {
					log.Printf("[server] pool[%d] ping timeout (no response for 9s), closing", idx)
					sc.Close()
					return
				}
				if sc.writeFrame(Frame{Type: tPing}) != nil {
					log.Printf("[server] pool[%d] failed to send ping, closing", idx)
					return
				}
			case <-pingDone:
				return
			}
		}
	}()

	if idx == 0 && transport == "tcp_stealth" {
		startChaff(sc.writeFrame, pingDone)
	}

	for {
		f, err := sc.readFrame()
		if err != nil {
			if err == io.EOF {
				log.Printf("[server] pool[%d] connection closed by peer", idx)
			} else {
				log.Printf("[server] pool[%d] read error: %v", idx, err)
			}
			break
		}
		switch f.Type {
		case tData:
			sess.pool.streamsMu.Lock()
			vconn, ok := sess.pool.streams[f.Stream]
			sess.pool.streamsMu.Unlock()
			if ok {
				payload := f.Data
				addRxBytes(len(payload))
				rxLimiter.wait(len(payload))
				vconn.Write(payload)
			}
		case tClose:
			sess.pool.streamsMu.Lock()
			if vconn, ok := sess.pool.streams[f.Stream]; ok {
				vconn.Close()
				delete(sess.pool.streams, f.Stream)
			}
			sess.pool.streamsMu.Unlock()
		case tPing:
			sc.writeFrame(Frame{Type: tPong})
		case tPong:
			atomic.StoreInt64(&lastPong, time.Now().UnixNano())
		}
	}

	close(pingDone)
	sess.pool.set(idx, nil)
	sc.Close()
}

func handleAccepted(conn net.Conn, cfg Config, srv *serverShared) {
	setNoDelay(conn)
	if normalizeTransport(cfg.Transport) == "tcp_stealth" {
		if err := readStealthPrefix(conn); err != nil {
			log.Printf("[server] failed to read stealth prefix from %v: %v", conn.RemoteAddr(), err)
			conn.Close()
			return
		}
	}
	marker := make([]byte, 1)
	if _, err := io.ReadFull(conn, marker); err != nil {
		log.Printf("[server] failed to read handshake marker from %v: %v", conn.RemoteAddr(), err)
		conn.Close()
		return
	}
	switch marker[0] {
	case 1:
		idxBuf := make([]byte, 1)
		if _, err := io.ReadFull(conn, idxBuf); err != nil {
			log.Printf("[server] failed to read pool index from %v: %v", conn.RemoteAddr(), err)
			conn.Close()
			return
		}
		idx := int(idxBuf[0])
		if idx < 0 || idx >= poolSize {
			log.Printf("[server] rejected connection from %v: invalid pool index %d", conn.RemoteAddr(), idx)
			conn.Close()
			return
		}
		sc, err := newSecureChannelServer(conn, cfg.Token)
		if err != nil {
			log.Printf("[server] key exchange failed with %v: %v", conn.RemoteAddr(), err)
			conn.Close()
			return
		}
		authFrame, err := sc.readFrame()
		if err != nil {
			log.Printf("[server] authentication failed from %v (likely wrong token): %v", conn.RemoteAddr(), err)
			sc.Close()
			return
		}
		if authFrame.Type != tAuth {
			log.Printf("[server] authentication failed from %v: unexpected first frame type %d", conn.RemoteAddr(), authFrame.Type)
			sc.Close()
			return
		}
		attachPoolConn(cfg, srv, idx, sc)
	case 2:
		idbuf := make([]byte, 4)
		if _, err := io.ReadFull(conn, idbuf); err != nil {
			log.Printf("[server] failed to read bind stream id from %v: %v", conn.RemoteAddr(), err)
			conn.Close()
			return
		}
		id := binary.BigEndian.Uint32(idbuf)
		srv.bindMu.Lock()
		vconn, ok := srv.pendingBinds[id]
		if ok {
			delete(srv.pendingBinds, id)
		}
		srv.bindMu.Unlock()
		if !ok {
			log.Printf("[server] bind connection for unknown or expired stream %d from %v", id, conn.RemoteAddr())
			conn.Close()
			return
		}
		pipeBoth(vconn, conn)
	default:
		log.Printf("[server] unknown marker %d from %v, dropping", marker[0], conn.RemoteAddr())
		conn.Close()
	}
}

func runServer(cfg Config) {
	ln, err := listenTransport(cfg)
	if err != nil {
		log.Fatal(err)
	}
	srv := &serverShared{pendingBinds: make(map[uint32]net.Conn)}
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleAccepted(conn, cfg, srv)
	}
}

func handleClassicBind(cfg Config, id uint32, localAddr string) {
	lconn, err := net.Dial("tcp", localAddr)
	if err != nil {
		log.Printf("[client] stream %d: failed to dial local service %s: %v", id, localAddr, err)
		return
	}
	setNoDelay(lconn)
	dconn, err := dialTransport(cfg)
	if err != nil {
		log.Printf("[client] stream %d: failed to open data connection to server: %v", id, err)
		lconn.Close()
		return
	}
	if normalizeTransport(cfg.Transport) == "tcp_stealth" {
		if err := writeStealthPrefix(dconn, 5); err != nil {
			log.Printf("[client] stream %d: failed to write stealth prefix: %v", id, err)
			lconn.Close()
			dconn.Close()
			return
		}
	}
	idbuf := make([]byte, 5)
	idbuf[0] = 2
	binary.BigEndian.PutUint32(idbuf[1:5], id)
	if _, err := dconn.Write(idbuf); err != nil {
		log.Printf("[client] stream %d: failed to send bind preamble: %v", id, err)
		lconn.Close()
		dconn.Close()
		return
	}
	pipeBoth(lconn, dconn)
}

func dialAndHandshakeClient(cfg Config, idx int) (*secureChannel, error) {
	conn, err := dialTransport(cfg)
	if err != nil {
		log.Printf("[client] pool[%d] dial failed: %v", idx, err)
		return nil, err
	}
	if normalizeTransport(cfg.Transport) == "tcp_stealth" {
		if err := writeStealthPrefix(conn, 2); err != nil {
			log.Printf("[client] pool[%d] failed to write stealth prefix: %v", idx, err)
			conn.Close()
			return nil, err
		}
	}
	if _, err := conn.Write([]byte{1, byte(idx)}); err != nil {
		log.Printf("[client] pool[%d] failed to write handshake preamble: %v", idx, err)
		conn.Close()
		return nil, err
	}
	sc, err := newSecureChannelClient(conn, cfg.Token)
	if err != nil {
		log.Printf("[client] pool[%d] key exchange failed: %v", idx, err)
		conn.Close()
		return nil, err
	}
	if err := sc.writeFrame(Frame{Type: tAuth, Data: []byte("ok")}); err != nil {
		log.Printf("[client] pool[%d] failed to send auth frame: %v", idx, err)
		sc.Close()
		return nil, err
	}
	log.Printf("[client] pool[%d] connected and authenticated", idx)
	return sc, nil
}

func clientPoolReadLoop(sc *secureChannel, idx int, cfg Config, p *pool, classic bool) {
	transport := normalizeTransport(cfg.Transport)
	pck := transport == "tcp_pck"
	var lastPong int64
	atomic.StoreInt64(&lastPong, time.Now().UnixNano())
	pingTicker := time.NewTicker(3 * time.Second)
	defer pingTicker.Stop()
	pingDone := make(chan struct{})
	go func() {
		for {
			select {
			case <-pingTicker.C:
				if time.Since(time.Unix(0, atomic.LoadInt64(&lastPong))) > 9*time.Second {
					log.Printf("[client] pool[%d] ping timeout (no response for 9s), closing", idx)
					sc.Close()
					return
				}
				if sc.writeFrame(Frame{Type: tPing}) != nil {
					log.Printf("[client] pool[%d] failed to send ping, closing", idx)
					return
				}
			case <-pingDone:
				return
			}
		}
	}()

	if idx == 0 && transport == "tcp_stealth" {
		startChaff(sc.writeFrame, pingDone)
	}

	for {
		f, err := sc.readFrame()
		if err != nil {
			if err == io.EOF {
				log.Printf("[client] pool[%d] connection closed by peer", idx)
			} else {
				log.Printf("[client] pool[%d] read error: %v", idx, err)
			}
			close(pingDone)
			break
		}
		switch f.Type {
		case tOpen:
			name := string(f.Data)
			addr, ok := cfg.Services[name]
			if !ok {
				sc.writeFrame(Frame{Type: tClose, Stream: f.Stream})
				continue
			}
			if classic {
				go handleClassicBind(cfg, f.Stream, addr)
			} else {
				lconn, err := net.Dial("tcp", addr)
				if err != nil {
					sc.writeFrame(Frame{Type: tClose, Stream: f.Stream})
					continue
				}
				setNoDelay(lconn)
				p.streamsMu.Lock()
				p.streams[f.Stream] = lconn
				p.streamsMu.Unlock()
				sc.writeFrame(Frame{Type: tOpened, Stream: f.Stream})
				go pumpToPool(p, f.Stream, lconn, pck, effectivePoolSize(transport))
			}
		case tData:
			p.streamsMu.Lock()
			lconn, ok := p.streams[f.Stream]
			p.streamsMu.Unlock()
			if ok {
				payload := f.Data
				addRxBytes(len(payload))
				rxLimiter.wait(len(payload))
				lconn.Write(payload)
			}
		case tClose:
			p.streamsMu.Lock()
			if lconn, ok := p.streams[f.Stream]; ok {
				lconn.Close()
				delete(p.streams, f.Stream)
			}
			p.streamsMu.Unlock()
		case tPing:
			sc.writeFrame(Frame{Type: tPong})
		case tPong:
			atomic.StoreInt64(&lastPong, time.Now().UnixNano())
		}
	}
}

func clientMaintainConn(cfg Config, idx int, p *pool, classic bool) {
	for {
		sc, err := dialAndHandshakeClient(cfg, idx)
		if err != nil {
			time.Sleep(2 * time.Second)
			continue
		}
		p.set(idx, sc)
		clientPoolReadLoop(sc, idx, cfg, p, classic)
		log.Printf("[client] pool[%d] disconnected, reconnecting", idx)
		p.set(idx, nil)
		time.Sleep(1 * time.Second)
	}
}

func runClient(cfg Config) {
	transport := normalizeTransport(cfg.Transport)
	classic := isClassic(transport)
	size := effectivePoolSize(transport)
	p := &pool{streams: make(map[uint32]net.Conn)}
	for i := 1; i < size; i++ {
		go clientMaintainConn(cfg, i, p, classic)
	}
	clientMaintainConn(cfg, 0, p, classic)
}

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: core <config.json>")
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Fatal(err)
	}
	statsPath := strings.TrimSuffix(os.Args[1], ".json") + ".stats.json"
	loadExistingStats(statsPath)
	go statsWriter(statsPath)
	setupRateLimiters(cfg.BandwidthMbps)
	switch cfg.Mode {
	case "server":
		runServer(cfg)
	case "client":
		runClient(cfg)
	default:
		log.Fatal("invalid mode")
	}
}

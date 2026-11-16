package main

import (
	"crypto/rand"
	"crypto/sha512"
	"fmt"
	"io"
	"strings"
)

const (
	cryptAlphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	cryptSaltLen  = 16
	cryptRounds   = 5000
)

func hashPassword(pw string) (string, error) {
	salt, err := cryptSalt()
	if err != nil {
		return "", err
	}
	return sha512Crypt(pw, salt), nil
}

func cryptSalt() (string, error) {
	b := make([]byte, cryptSaltLen)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return "", fmt.Errorf("no random bytes for salt: %w", err)
	}
	for i, v := range b {
		b[i] = cryptAlphabet[v%64]
	}
	return string(b), nil
}

// sha512Crypt implements Ulrich Drepper's SHA-512 crypt ($6$) specification.
func sha512Crypt(pw, salt string) string {
	key := []byte(pw)
	if len(salt) > cryptSaltLen {
		salt = salt[:cryptSaltLen]
	}
	s := []byte(salt)

	bSum := sha512.Sum512(concatBytes(key, s, key))
	b := bSum[:]

	ac := sha512.New()
	ac.Write(key)
	ac.Write(s)
	ac.Write(cryptSeq(b, len(key)))
	for n := len(key); n > 0; n >>= 1 {
		if n&1 != 0 {
			ac.Write(b)
		} else {
			ac.Write(key)
		}
	}
	a := ac.Sum(nil)

	p := cryptSeq(sumRepeat(key, len(key)), len(key))
	sq := cryptSeq(sumRepeat(s, 16+int(a[0])), len(s))

	cur := a
	for i := range cryptRounds {
		c := sha512.New()
		if i%2 != 0 {
			c.Write(p)
		} else {
			c.Write(cur)
		}
		if i%3 != 0 {
			c.Write(sq)
		}
		if i%7 != 0 {
			c.Write(p)
		}
		if i%2 != 0 {
			c.Write(cur)
		} else {
			c.Write(p)
		}
		cur = c.Sum(cur[:0:sha512.Size])
	}
	return "$6$" + salt + "$" + cryptEncode(cur)
}

func cryptEncode(d []byte) string {
	var sb strings.Builder
	sb.Grow(86)
	emit := func(w, n int) {
		for ; n > 0; n-- {
			sb.WriteByte(cryptAlphabet[w&0x3f])
			w >>= 6
		}
	}
	x, y, z := 0, 21, 42
	for range 21 {
		emit(int(d[x])<<16|int(d[y])<<8|int(d[z]), 4)
		x, y, z = y+1, z+1, x+1
	}
	emit(int(d[63]), 2)
	return sb.String()
}

func cryptSeq(d []byte, n int) []byte {
	out := make([]byte, 0, n)
	for len(out) < n {
		out = append(out, d[:min(n-len(out), len(d))]...)
	}
	return out
}

func sumRepeat(b []byte, n int) []byte {
	h := sha512.New()
	for range n {
		h.Write(b)
	}
	return h.Sum(nil)
}

func concatBytes(parts ...[]byte) []byte {
	n := 0
	for _, p := range parts {
		n += len(p)
	}
	out := make([]byte, 0, n)
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

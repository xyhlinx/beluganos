// -*- coding: utf-8 -*-

// Copyright (C) 2017 Nippon Telegraph and Telephone Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package nladbm

import (
	"sync"
	"sync/atomic"
)

//
// Topic interface
//
type Stat interface {
	Inc()
	Add(uint64)
	Get() (string, uint64)
}

type StatTable interface {
	New(string) Stat
	Walk(func(Stat) error) error
}

func NewStat(name string) Stat {
	return &NLAStat{
		Counter: 0,
		Name:    name,
	}
}

func NewStatTable() StatTable {
	return &NLAStatTable{
		Topics: []Stat{},
	}
}

//
// Topic
//
type NLAStat struct {
	Counter uint64
	Name    string
}

func (n *NLAStat) Inc() {
	atomic.AddUint64(&n.Counter, 1)
}

func (n *NLAStat) Add(delta uint64) {
	atomic.AddUint64(&n.Counter, delta)
}

func (n *NLAStat) Get() (string, uint64) {
	return n.Name, atomic.LoadUint64(&n.Counter)
}

//
// Table
//
type NLAStatTable struct {
	Mutex  sync.RWMutex
	Topics []Stat
}

func (n *NLAStatTable) New(name string) Stat {
	n.Mutex.Lock()
	defer n.Mutex.Unlock()

	t := NewStat(name)
	n.Topics = append(n.Topics, t)

	return t
}

func (n *NLAStatTable) Walk(f func(Stat) error) error {
	n.Mutex.RLock()
	defer n.Mutex.RUnlock()

	for _, topic := range n.Topics {
		if err := f(topic); err != nil {
			return err
		}
	}

	return nil
}

#!/usr/bin/env tarantool
local test = require('tap').test()
test:plan(3)

local test_user = 'test'
local test_pass = '1234'
local test_host = 'localhost'
local test_port = '3388'

local uri = require('uri')
local netbox = require('net.box')

local tnt = require('t.tnt')

tnt.cfg{
    listen = uri.format({ host = test_host, service = test_port })
}

local qc = require('queue.compat')

test:test('check for space grants', function(test)
    -- prepare for tests
    local queue = require('queue')
    box.schema.user.create(test_user, { password = test_pass })

    test:plan(5)

    local tube = queue.create_tube('test', 'fifo')
    tube:put('help');
    local task = tube:take();
    test:is(task[1], 0, 'we can get record')
    tube:release(task[1])

    -- checking without grants
    box.session.su('test')
    local stat, er = pcall(tube.take, tube)
    test:is(stat, false, 'we\'re getting error')
    box.session.su('admin')

    -- checking with grants
    tube:grant('test')
    box.session.su('test')
    local a = tube:take()
    test:is(a[1], 0, 'we aren\'t getting any error')
    local b = tube:take(0.1)
    test:isnil(b, 'we aren\'t getting any error')
    local c = tube:ack(a[1])
    test:is(a[1], 0, 'we aren\'t getting any error')
    box.session.su('admin')

    -- checking double grants
    tube:grant('test')

    box.schema.user.drop(test_user)
    tube:drop()
end)

test:test('check for call grants', function(test)
    -- prepare for tests
    _G.queue = require('queue')
    box.schema.user.create(test_user, { password = test_pass })

    test:plan(9)

    local tube = queue.create_tube('test', 'fifo')
    tube:put('help');
    local task = tube:take();
    test:is(task[1], 0, 'we can get record')
    tube:release(task[1])

    -- checking without grants
    box.session.su('test')
    local stat, er = pcall(tube.take, tube)
    test:is(stat, false, 'we\'re getting error')
    box.session.su('admin')

    -- checking with grants
    tube:grant('test')

    box.session.su('test')
    local a = tube:take()
    test:is(a[1], 0, 'we aren\'t getting any error')
    local b = tube:take(0.1)
    test:isnil(b, 'we aren\'t getting any error')
    local c = tube:release(a[1])
    test:is(a[1], 0, 'we aren\'t getting any error')
    box.session.su('admin')

    local con = netbox.connect(uri.format({
        login = test_user, password = test_pass,
        host  = test_host, service  = test_port,
    }, true))

    local stat, er = pcall(con.call, con, tube, 'queue.tube.test:take')
    test:is(stat, false, 'we\'re getting error')

    -- granting call
    tube:grant('test', { call = true })

    local a = con:call('queue.tube.test:take')
    test:is(a[1], 0, 'we aren\'t getting any error')
    local b = con:call('queue.tube.test:take', qc.pack_args(0.1))
    test:isnil(b, 'we aren\'t getting any error')
    local c = con:call('queue.tube.test:ack',  qc.pack_args(a[1]))
    test:is(a[1], 0, 'we aren\'t getting any error')

    -- check grants again
    tube:grant('test', { call = true })

    _G.queue = nil
    tube:drop()
end)

test:test('check tube existence', function(test)
    test:plan(14)
    local queue = require('queue')
    test:is(#queue.tube(), 0, 'checking for empty tube list')
    assert(#queue.tube() == 0)

    local tube1 = queue.create_tube('test1', 'fifo')
    test:is(#queue.tube(), 1, 'checking for not empty tube list')

    local tube2 = queue.create_tube('test2', 'fifo')
    test:is(#queue.tube(), 2, 'checking for not empty tube list')

    test:is(queue.tube('test1'), true, 'checking for tube existence')
    test:is(queue.tube('test2'), true, 'checking for tube existence')
    test:is(queue.tube('test3'), false, 'checking for tube nonexistence')

    tube2:drop()
    test:is(#queue.tube(), 1, 'checking for not empty tube list')

    test:is(queue.tube('test1'), true, 'checking for tube existence')
    test:is(queue.tube('test2'), false, 'checking for tube nonexistence')
    test:is(queue.tube('test3'), false, 'checking for tube nonexistence')

    tube1:drop()
    test:is(#queue.tube(), 0, 'checking for empty tube list')

    test:is(queue.tube('test1'), false, 'checking for tube nonexistence')
    test:is(queue.tube('test2'), false, 'checking for tube nonexistence')
    test:is(queue.tube('test3'), false, 'checking for tube nonexistence')
end)

tnt.finish()

os.exit(test:check() == true and 0 or -1)
-- vim: set ft=lua :

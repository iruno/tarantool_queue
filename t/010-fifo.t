#!/usr/bin/env tarantool
-- vim: set ft=lua :

local fiber = require 'fiber'
local test = (require 'tap').test()
local tnt  = require 't.tnt'
local state = require 'queue.abstract.state'
local yaml = require 'yaml'
test:plan(12)

test:ok(rawget(box, 'space'), 'box started')

local queue = require 'queue.abstract'
test:ok(queue.start(), 'queue.start()')
test:ok(queue, 'queue is loaded')

local tube = queue.create_tube('test', 'fifo')
local tube2 = queue.create_tube('test_stat', 'fifo')
test:ok(tube, 'test tube created')
test:is(tube.name, 'test', 'tube.name')
test:is(tube.type, 'fifo', 'tube.type')

test:test('Fifo statistics', function(test)
    test:plan(13)
    tube2:put('stat_0')
    tube2:put('stat_1')
    tube2:put('stat_2')
    tube2:put('stat_3')
    tube2:put('stat_4')
    tube2:delete(4)
    tube2:take(.001)
    tube2:release(0)
    tube2:take(.001)
    tube2:ack(0)
    tube2:bury(1)
    tube2:bury(2)
    tube2:kick(1)
    tube2:take(.001)

   local stats = queue.statistics('test_stat')

   -- check tasks statistics
   test:is(stats.tasks.taken, 1, 'tasks.taken')
   test:is(stats.tasks.buried, 1, 'tasks.buried')
   test:is(stats.tasks.ready, 1, 'tasks.ready')
   test:is(stats.tasks.done, 2, 'tasks.done')
   test:is(stats.tasks.delayed, 0, 'tasks.delayed')
   test:is(stats.tasks.total, 3, 'tasks.total')

   -- check function call statistics
   test:is(stats.calls.delete, 1, 'calls.delete')
   test:is(stats.calls.ack, 1, 'calls.ack')
   test:is(stats.calls.take, 3, 'calls.take')
   test:is(stats.calls.kick, 1, 'calls.kick')
   test:is(stats.calls.bury, 2, 'calls.bury')
   test:is(stats.calls.put, 5, 'calls.put')
   test:is(stats.calls.release, 1, 'calls.release')
end)

test:test('Easy put/take/ack', function(test)
    test:plan(5)

    test:ok(tube:put{123}, 'task was put')
    local task = tube:take()
    test:ok(task, 'task was taken')
    test:is(task[2], 't', 'task status')
    task = tube:ack(task[1])
    test:ok(task, 'task was acked')
    test:is(task[2], '-', 'task status')
end)


test:test('fifo', function(test)
    test:plan(5)

    test:test('order', function(test)
        test:plan(16)
        test:ok(tube:put('first'), 'put task 1')
        test:ok(tube:put(2), 'put task 2')
        test:ok(tube:put('third'), 'put task 3')
        test:ok(tube:put(4), 'put task 4')

        local task1 = tube:take()
        test:ok(task1, 'task 1 was taken')
        test:is(task1[2], 't', 'task1 status')
        test:is(task1[3], 'first', 'task1.data')

        local task2 = tube:take()
        test:ok(task2, 'task 2 was taken')
        test:is(task2[2], 't', 'task2 status')
        test:is(task2[3], 2, 'task2.data')

        local task3 = tube:take()
        test:ok(task3, 'task 3 was taken')
        test:is(task3[2], 't', 'task3 status')
        test:is(task3[3], 'third', 'task3.data')

        local task4 = tube:take()
        test:ok(task4, 'task 4 was taken')
        test:is(task4[2], 't', 'task4 status')
        test:is(task4[3], 4, 'task4.data')
    end)

    test:test('timeouts', function(test)
        test:plan(3)

        test:isnil(tube:take(.1), 'task was not taken: timeout')

        fiber.create(function()
            test:ok(tube:take(1), 'task was taken')
        end)

        fiber.sleep(0.1)
        test:ok(tube:put(123), 'task was put')
        fiber.sleep(0.1)
    end)

    test:test('release', function(test)
        test:plan(20)
        test:ok(tube:put('first'), 'put task 1')
        test:ok(tube:put(2), 'put task 2')
        test:ok(tube:put('third'), 'put task 3')
        test:ok(tube:put(4), 'put task 4')

        local task1 = tube:take()
        test:ok(task1, 'task 1 was taken')
        test:is(task1[2], 't', 'task1 status')
        test:is(task1[3], 'first', 'task1.data')

        local task2 = tube:take()
        test:ok(task2, 'task 2 was taken')
        test:is(task2[2], 't', 'task2 status')
        test:is(task2[3], 2, 'task2.data')


        test:ok(tube:release(task1[1]), 'task1 was released')

        local task1a = tube:take()
        test:ok(task1a, 'task 1 was taken again')
        test:is(task1a[2], 't', 'task1 status')
        test:is(task1a[3], 'first', 'task1.data')

        local task3 = tube:take()
        test:ok(task3, 'task 3 was taken')
        test:is(task3[2], 't', 'task3 status')
        test:is(task3[3], 'third', 'task3.data')

        local task4 = tube:take()
        test:ok(task4, 'task 4 was taken')
        test:is(task4[2], 't', 'task4 status')
        test:is(task4[3], 4, 'task4.data')
    end)

    test:test('release timeouts', function(test)
        test:plan(5)

        test:ok(tube:put('test123'), 'task was put')
        local task = tube:take(.1)
        test:is(task[3], 'test123', 'task.data')

        fiber.create(function()
            local task = tube:take(1)
            test:ok(task, 'task was taken')
            test:is(task[3], 'test123', 'task.data')
        end)

        fiber.sleep(0.1)
        test:ok(tube:release(task[1]), 'task was released')
        fiber.sleep(0.1)
    end)


    test:test('bury/kick/delete/peek', function(test)
        test:plan(18)
        test:ok(tube:put('first'), 'put task 1')
        test:ok(tube:put(2), 'put task 2')
        test:ok(tube:put('third'), 'put task 3')
        test:ok(tube:put(4), 'put task 4')

        local task1 = tube:take()
        local task2 = tube:take()
        local task3 = tube:take()
        local task4 = tube:take()

        task1 = tube:bury(task1[1])
        test:is(task1[2], state.BURIED, 'task1 is buried')
        test:ok(tube:bury(task2[1]), 'task2 is buried')
        test:ok(tube:bury(task3[1]), 'task3 is buried')
        test:ok(tube:bury(task4[1]), 'task4 is buried')

        fiber.create(function()
            for i = 1, 3 do
                tube:take()
            end
        end)

        fiber.sleep(0.1)
        test:is(tube:kick(3), 3, '3 tasks were kicken')
        fiber.sleep(0.1)

        test:is(tube:peek(task1[1])[2], state.TAKEN, 'task1 unburied and taken')
        test:is(tube:peek(task2[1])[2], state.TAKEN, 'task2 unburied and taken')
        test:is(tube:peek(task3[1])[2], state.TAKEN, 'task3 unburied and taken')
        test:is(tube:peek(task4[1])[2], state.BURIED, 'task4 is still buried')

        test:is(tube:kick(100500), 1, 'one task was unburied')
        test:is(tube:peek(task4[1])[2], state.READY, 'task4 unburied and ready')
        test:is(tube:delete(task4[1])[2], state.DONE, 'task4 was removed')

        local s, e = pcall(function() tube:peek(task4[1]) end)
        test:ok(not s, "Task not found exception")
        test:ok(string.match(e, "Task %d+ not found") ~= nil,
            "Task not found message")

    end)
end)

test:test('creating existing tube', function(test)
    test:plan(2)
    local s, e = pcall(function() queue.create_tube('test', 'fifo') end)
    test:ok(not s, 'exception was thrown')
    test:is(e, 'Space test already exists', 'text of exception')
end)

test:test('tempspace', function(test)
    test:plan(2)
    tube = queue.create_tube('test1', 'fifo', { temporary = true })
    test:ok(tube, 'tube was created')
    local space_r = box.space._space:get{queue.tube.test1.raw.space.id}
    test:ok(string.match(space_r[6], 'temporary') ~= nil, 'really tempspace')
end)

test:test('disconnect test', function(test)
    test:plan(6)

    tube:put(1)
    tube:put(2)
    tube:put(3)

    local task1 = tube:take(.1)
    test:ok(task1, 'task1 was taken')
    local task2 = tube:take(.1)
    test:ok(task2, 'task2 was taken')
    local task3 = tube:take(.1)
    test:ok(task3, 'task3 was taken')


    queue._on_consumer_disconnect()

    test:is(tube:peek(task1[1])[2], state.READY, 'task1 was marked as READY')
    test:is(tube:peek(task2[1])[2], state.READY, 'task2 was marked as READY')
    test:is(tube:peek(task3[1])[2], state.READY, 'task3 was marked as READY')
end)


tnt.finish()
test:check()
os.exit()

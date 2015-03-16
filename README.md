# A collection of persistent queue implementations for Tarantool 1.6
[![Build Status](https://travis-ci.org/tarantool/queue.svg?branch=master)](https://travis-ci.org/tarantool/queue)
## `fifo` - a simple queue

Features:

* in case there is no more than one consumer, tasks are scheduled in strict FIFO order
* for many concurrent consumers, FIFO is preserved but is less strict: concurrent consumers may complete tasks in different order; on average, FIFO is preserved
* Available properties of queue object:
 * `temporary` - if true, the queue is in-memory only (the contents does not persist on disk)
 
`fifo` queue does not support:
 * task priorities
 * task time to live (`ttl`), execute (`ttr`), delayed tasks (`delay` option)


## `fifottl` - a simple priority queue with task time to live support

The following options can be supplied when creating a queue:
 * `temporary` - if true, the content of the queue does not persist on disk
 * `ttl` - time to live for a task put into the queue; if `ttl` is not given, it's set to infinity
 * `ttr` - time allotted to the worker to work on a task; if not set, is the same as `ttl`
 * `pri` - task priority (`0` is the highest priority and is the default)
 
When a message (task) is pushed into a `fifottl` queue, the following options can be set:
`ttl`, `ttr`, `pri`, and`delay`

Example:

```lua

queue.tube.tube_name:put('my_task_data', { ttl = 60.1, delay = 80 })

```

In the example above, the task has 60.1 seconds to live, but execution is postponed for 80 secods. Delayed start automatically extends the time to live of a task to the amount of the delay, thus the actual time to live is 140.1 seconds.

The value of priority is **lowest** for the **highest**. In other words, a task with priority 1 is executed after the task with priority 0, all other options being equal.

## `utube` - a queue with micro-queues inside

The main idea of this queue backend is the same as in `fifo` queue: the tasks are executed in FIFO order, there is no `ttl`/`ttr`/`delay`/`priority` support.

The main new feature of this queue is that each `put` call accepts a new option, `utube` - the name of the sub-queue.
The sub-queues split the task stream according to subqueue name: it's not possible to take two tasks
out of a sub-queue concurrently, ech sub-queue is executed in strict FIFO order, one task at a time.

### Example: 

Imagine a web-crawler, к, обходящий множество страниц разных сайтов.
Этот паук написан в виде воркера к очереди, задания которой представляют собой
урлы. Если воркеров запущено большое число, а в качестве заданий в очереди
попадается многократно один и тот же сайт, то эти воркеры работая параллельно
могут устроить данному сайту DDOS.

Если указать например имя домена в качестве имени микроочереди для каждого
таска, то проблема перегрузки клиентского сайта будет решена: не более одного
воркера будет делать запросы на один домен.


## `utubettl` - extention of `utube` to support `ttl`

Работает аналогично `fifottl` и `utube`

# Схема очереди

Данная глава информационная. По идее пользователю эта информация не
требуется.

Очередь работает со спецспейсом `_queue`, который либо создает
сама при первом `init`, либо использует созданный ей же ранее.

#### Структура спейса `_queue`

1. `tube` - имя очереди
1. `tube_id` - числовой ID очереди
1. `space` - имя спейса, связанного с очередью
1. `type` - тип очереди
1. `opts` - дополнительные опции по данной очереди

Так же создается два спецспейса с флагом `temporary = true`:

#### Список ожидающих заданий консьюмеров `_queue_consumers`

1. `session` - id сессии в которой пришел клиент
1. `fid` - id файбера клиента
1. `tube_id` - id очереди, которую ждет данный клиент
1. `timeout` - когда у клиента истечет терпение и он уйдет
1. `time` - когда клиент начал ждать


#### Список задач находящихся на выполнении `_queue_taken`

1. `session` - id сессии с которой пришел клиент
1. `tube_id` - id очереди в которой он выполняет сейчас таск
1. `task_id` - id задачи, которую он сейчас выполняет
1. `time` - когда он начал выполнять задачу

# API

## Все таски представляют из себя таплы из трех элементов:

1. id задачи
1. статус задачи
1. данные связанные с задачей

Статусы задачи могут быть следующими (разные очереди могут поддерживать
разные наборы статусов):

* `r` - задача готова к обработке (первый `consumer`'ом, который сделает запрос
`take` - получит ее на выполнение)
* `t` - задача взята в обработку каким-то `consumer`'ом
* `-` - задача выполнена (реально - удалена из очереди)
* `!` - задача закопана
* `~` - задача отложена на некоторое время

ID задачам назначает очередь. в настоящее время это целочисленные ID
для очередей `fifo` и `fifottl`.


## Подключение очереди

```lua
    local queue = require 'queue'
```

Операция `require` создает спецспейс `_queue` (если он не создан), а так
же устанавливает все необходимые триггеры итп.

## Создание очереди

```
    queue.schema.create_tube(name, type, { ... })
```

Создает очередь.

Пока поддерживаются следующие типы:

1. `fifo` - таски обрабатываются в порядке поступления.
нарушение порядка возможно только при наличии нескольких воркеров, которые
работают с разной скоростью и (или) отваливаются.
1. `fifottl` - таски обрабатываются в порядке поступления.
Таски и очередь в настройках имеют предзаданное время жизни (`ttl`) и время
исполнения (`ttr`).
1. `utube` - очередь микроочередей
1. `utubettl` - очередь микроочередей с поддержкой `ttl`, `ttr` итп

## Продюсер

Положить таск в очередь можно командой

```lua
queue.tube.tube_name:put(task_data[, opts])
```

Опции `opts` в общем случае необязательны, если не указаны, то берутся из
общих настроек очереди (или устанавливаются в то или иное дефолтное значение).

Общие для всех очередей опции (разные очереди могут не поддерживать те или иные
опции):

* `ttl` - время жизни таска в секундах. Спустя данное время, если таск не был
взят ни одним консьюмером таск удаляется из очереди.
* `ttr` - время отведенное на выполнение таска консьюмером. Если консюмер не
уложился в это время, то таск возвращается в состояние `READY` (и его сможет
взять на выполнение другой консюмер). По умолчанию равно `ttl`.
* `pri` - приоритет задачи.
* `delay` - отложить выполнение задачи на указанное число секунд.

Возвращает созданную задачу.

## Консюмер

Получить таск на выполнение можно командой

```lua
queue.tube.tube_name:take([timeout])
```

Ожидает `timeout` секунд до появления задачи в очереди.
Возвращает задачу или пустой ответ.


После выполнения задачи консюмером необходимо сделать для задачи `ack`:

```lua
queue.tube.tube_name:ack(task_id)
```

Необходимо отметить:

1. `ack` может делать только тот консюмер, который взял задачу на исполнение
1. при разрыве сессии с консюмером, все взятые им задачи переводятся в состояние
"готова к исполнению" (то есть им делается принудительный `release`)

Если консюмер по какой-то причине не может выполнить задачу, то он может
вернуть ее в очередь:

```lua
queue.tube.tube_name:release(task_id, opts)
```

в опциях можно передавать задержку на последующее выполнение (для очередей,
которые поддерживают отложенное исполнение) - `delay`.


## Другие запросы

Посмотреть на задачу зная ее ID можно испльзуя запрос

```lua

local task = queue.tube.tube_name:peek(task_id)

```

Если воркер понял что с задачей что-то не то и она не может быть выполнена
то он (и не только он) может ее закопать вызвав метод

```lua

queue.tube.tube_name:bury(task_id)

```

Откопать заданное количество проблемных задач можно функцией `kick`:

```lua

queue.tube.tube_name:kick(count)

```

Удалить задачу зная ее ID можно функцией `delete`:

```lua

queue.tube.tube_name:delete(task_id)

```


Удалить очередь целиком (при условии что в ней нет исполняющихся
задач или присоединенных воркеров можно при помощи функции drop:

```lua

queue.tube.tube_name:drop()

```


# Описание собственно реализации

Реализация опирается на общие для всех очередей вещи:

1. контроль за `consumer`'ами (ожидание/побудка итп)
1. единообразный API
1. создание спейсов
1. итп

соответственно каждая новая очередь описывается драйвером.

## Драйверы очередей

Основные требования

1. Поддерживает понятия:
 * ненормализованный таск (внутреннее строение таска) - таппл.
   единственное требование: первое поле - ID, второе поле - состояние.
 * нормализованный таск (описан выше)
1. При каждом изменении состояния таска по любой причине (как инициированной
очередью, так и инициированной внутренними нуждами) должен уведомить
основную систему об этом уведомлении.
1. Не выбрасывает исключения вида "задачи нет в очереди" (но может
выбрасывать исключения вида "неверные параметры вызова")

## API драйверов

1. метод `new` (конструктор объекта). принимает два аргумента:
 * спейс (объект) с которым работает данный драйвер
 * функцию для уведомления всей системы о происходящих изменениях
 (`on_task_change`)
 * опции (таблица) очереди
1. метод `create_space` - создание спейса. передаются два аргумента
 * имя спейса
 * опции очереди

Таким образом когда пользователь просит у системы создать новую очередь,
то система просит у драйвера создать спейс для этой очереди, затем
конструирует объект передавая ему созданный спейс.

Объект конструируется так же и в случае когда очередь просто стартует
вместе с запуском тарантула.

Каждый объект очереди имеет следующее API:

* `tube:normalize_task(task)` - должен привести таск к обобщенному виду
  (вырезать из него все ненужные пользователю данные)
* `tube:put(data[, opts])` - положить задачу в очередь. Возвращает
ненормализованный таск (запись в спейсе).
* `tube:take()` - берет задачу готовую к выполнению из очереди (помечая
ее как "выполняющаяся"). Если таких задач нет - возвращает nil
* `tube:delete(task_id)` - удаление задачи из очереди
* `tube:release(task_id, opts)` - возврат задачи в очередь
* `tube:bury(task_id)` - закопать задачу
* `tube:kick(count)` - откопать `count` задач
* `tube:peek(task_id)` - выбрать задачу по ID

For Tarantool 1.5 Queue see [stable branch](https://github.com/tarantool/queue/tree/stable/)

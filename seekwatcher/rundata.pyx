import numpy
import sys
cimport numpy

cdef extern from "math.h":
    float floor(float val)
    float ceil(float val)

cdef float QUEUE_EVENT = 0.0
cdef float COMPLETION_EVENT = 1.0
cdef float DISPATCH_EVENT = 4.0
ctypedef numpy.float_t DTYPE_t

cdef float flag2num(flag):
    flag = flag[0]
    if flag == 'Q':
        return QUEUE_EVENT
    if flag == 'C':
        return COMPLETION_EVENT
    if flag == 'U':
        return 2.0
    if flag == 'D':
        return DISPATCH_EVENT
    return 3.0
    sys.stderr.write("unknown flag %s\n" %flag)

cdef float command2num(com):
    start = com[0]
    if start == 'R':
        return 0.0
    if start == 'W':
        return 1.0
    return 2.0
    sys.stderr.write("unknown command %s\n" % com)

cdef float dev2num(dev):
    s2 = dev.replace(',', '.')
    return float(s2)

cdef int ROWINC = 16384

#
# the rundata class holds all underlying data used to create each graph.
# seeks, throughput and iops are calculated once as we load the data
# in, and then the data is filtered to only include enough for the
# movies and IO graph.  If we aren't doing the IO graph, the
# data is stripped almost bare.
#
cdef class rundata:
    cdef public seek_hist
    cdef public seeks
    cdef public tput
    cdef public iops
    cdef public stats
    cdef public last_seek
    cdef public last_tput
    cdef public last_time
    cdef public last_iops
    cdef public last_line
    cdef public data
    cdef int found_issued
    cdef int found_completion
    cdef int found_queue
    cdef int data_rows
    cdef int data_filled

    def add_data_row(self, numpy.ndarray[DTYPE_t, ndim=2] data,
            numpy.ndarray[DTYPE_t, ndim=1] row):

        cdef int index = self.data_filled
        if self.data_filled == self.data_rows:
            extend = numpy.empty((ROWINC, 10), dtype=float)
            data = numpy.append(self.data, extend, axis=0)
            self.data = data
            self.data_rows += ROWINC
        i = 0
        while i < 10:
            data[index,i] = row[i]
            i += 1
        self.data_filled += 1
    
    def __init__(self):
        self.seek_hist = {}
        self.seeks = {}
        self.tput = {}
        self.iops = {}
        self.stats = {}
        self.last_seek = None
        self.last_tput = None
        self.last_iops = None
        self.last_time = None
        self.last_line = None
        self.data = numpy.empty((ROWINC, 10), dtype=float)
        self.data_rows = ROWINC
        self.data_filled = 0
        self.found_issued = False
        self.found_completion = False
        self.found_queue = False

    def add_seek(self, numpy.ndarray[DTYPE_t, ndim=1] data, float cur_time):
        cdef float dev = data[8]
        cdef float sector = data[4]
        cdef float io_size = data[5] / 512
        cdef last
        cdef last_size
        cdef float old

        last, last_size = self.seek_hist.get(dev, (None, None))

        if last != None:
            diff = abs((last + last_size) - sector)
            if diff > 128:
                old = self.seeks.get(cur_time, 0)
                self.seeks[cur_time] = old + 1
        self.seek_hist[dev] = (sector, io_size)
        self.last_seek = data
        self.last_time = data[7]

    def add_tput(self, numpy.ndarray[DTYPE_t, ndim=1] data, float cur_time):
        cdef float io_size = data[5]
        cdef float old = self.tput.get(cur_time, 0)

        self.tput[cur_time] = old + io_size
        self.last_tput = data
        self.last_time = data[7]

    def add_iop(self, numpy.ndarray[DTYPE_t, ndim=1] data, float cur_time):
        cdef float old = self.iops.get(cur_time, 0)
        self.iops[cur_time] = old + 1
        self.last_iops = data
        self.last_time = data[7]

    def add_line(self, numpy.ndarray[DTYPE_t, ndim=1] data):
        cdef float op = data[0]
        self.last_line = data
        floor_time = floor(data[7])

        # for seeks, we want to use the dispatch event
        # and if those aren't in the trace we want
        # the queued event, and if those aren't in
        # the trace, we want the completion event
        if op == DISPATCH_EVENT:
            # dispatch
            self.add_seek(data, floor_time)
        elif op == COMPLETION_EVENT and not self.found_issued and not \
                self.found_queue:
            # completion
            self.add_seek(data, floor_time)
        elif op == QUEUE_EVENT and not self.found_issued:
            # queue
            self.add_seek(data, floor_time)

        # for tput and iops, we want to use the completion event
        # otherwise dispatch, otherwise queue
        if op == COMPLETION_EVENT:
            self.add_tput(data, floor_time)
            self.add_iop(data, floor_time)
        elif op == DISPATCH_EVENT and not self.found_completion:
            self.add_tput(data, floor_time)
            self.add_iop(data, floor_time)
        elif op == QUEUE_EVENT and not self.found_completion and not \
                self.found_issued:
            self.add_tput(data, floor_time)
            self.add_iop(data, floor_time)

    def load_data(self, fh, delimiter, io_plot,
            devices_sector_max, tags, options):

        cdef int total_lines = 0
        cdef int total_out = 0
        cdef int first_line = 0
        cdef float last_sector = 0
        cdef float last_rw = 0
        cdef float last_end = 0
        cdef float last_cmd = 0
        cdef float last_size = 0
        cdef float last_dev = 0
        cdef float last_tag = 0
        cdef tag_data
        cdef numpy.ndarray[DTYPE_t, ndim=1] last_row = None
        cdef numpy.ndarray[DTYPE_t, ndim=1] row = None
        cdef val
        cdef start
        cdef int should_tag = options.tag_process
        cdef writes_only = options.writes_only
        cdef reads_only = options.reads_only
        cdef int io_seeks_only = options.only_io_graph_seeks
        cdef int i
        cdef int this_tag
        cdef float this_op
        cdef float this_time
        cdef float this_dev
        cdef float this_sector
        cdef float this_rw
        cdef float this_size

        row = numpy.empty(10)
        for i,line in enumerate(fh):
            if len(line) == 0:
                continue

            start = line[0]
            if not start == 'Q' and not start == 'D' and not start == 'C':
                continue

            if not self.found_completion and start == 'C':
                self.found_completion = 1
            if not self.found_queue and start == 'Q':
                self.found_queue = 1
            if not self.found_issued and start == 'D':
                self.found_issued = 1

            v = line.split(delimiter)
            i = 0
            while i < len(v):
                if i == 0:
                    row[0] = flag2num(v[i])
                elif i == 1:
                    row[1] = command2num(v[i])
                elif i == 8:
                    row[8] = dev2num(v[i])
                elif i < 9:
                    row[i] = float(v[i])
                elif should_tag:
                    if i == 9:
                        tag_data = [v[i]]
                    elif i > 9:
                        tag_data.append(v[i])
                i += 1

            this_op = row[0]
            if this_op == QUEUE_EVENT and should_tag:
                if 'all' in options.merge or \
                        options.merge.count(tag_data[1]) > 0:
                    val = tag_data[1]
                else:
                    val = tag_data[1] + "(" + tag_data[0] + ")"
                this_tag = tags.setdefault(val, len(tags))

            row[9] = this_tag
            this_time = row[7]
            this_dev = row[8]
            this_sector = row[4]
            this_rw = row[1]
            this_size = row[5] / 512

            total_lines += 1
            if writes_only and this_rw == 0:
                continue
            if reads_only and this_rw == 1:
                continue

            self.add_line(row)

            devices_sector_max[this_dev] = max(this_sector + this_size,
                                    devices_sector_max.get(this_dev, 0));
            # everything from here on is for the IO graph.
            # so we try to cut down on the stuff we keep in ram
            if not io_plot:
                if not first_line:
                    self.add_data_row(self.data, self.last_line)
                    first_line = 1
                continue

            if should_tag:
                if this_op != QUEUE_EVENT and self.found_queue:
                    continue
                if this_op == DISPATCH_EVENT and self.found_completion:
                    continue

            elif io_seeks_only:
                if this_op == COMPLETION_EVENT and (self.found_queue or
                        self.found_issued):
                    continue
                if this_op == QUEUE_EVENT and self.found_issued:
                    continue
            else:
                if this_op == QUEUE_EVENT and (self.found_completion or
                        self.found_issued):
                    continue
                if this_op == DISPATCH_EVENT and self.found_completion:
                    continue

            if last_row != None:
                if (this_op == last_op and 
                this_rw == last_rw and
                this_dev == last_dev and
                this_time - last_time < .5 and last_size < 1024 and
                this_sector == last_end and this_tag == last_tag):
                    last_end += this_size
                    last_size += this_size
                    last_row[5] += row[5]
                    continue
                total_out += 1
                self.add_data_row(self.data, last_row)
                
            last_row = row
            last_op = this_op
            last_sector = this_sector
            last_time = this_time
            last_rw = this_rw
            last_end = this_sector + this_size
            last_size = this_size
            last_dev = this_dev
            last_tag = this_tag

        if last_row != None:
            if last_row.any():
                self.add_data_row(self.data, last_row)
                total_out += 1

        self.data = numpy.resize(self.data, (self.data_filled, 10))
        self.data_rows = self.data_filled

    def translate_run(self, devices_sector_max, device_translate):
        cdef int i
        cdef numpy.ndarray[DTYPE_t, ndim=2] data = self.data
        cdef numpy.ndarray[DTYPE_t, ndim=1] row

        if len(devices_sector_max) > 1:
            i = 0
            while i < self.data_filled:
                row = data[i]
                sector = row[4]
                row[4] = device_translate[row[8]] + sector
                i += 1

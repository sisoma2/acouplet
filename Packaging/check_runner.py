from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from functools import partial
import argparse
import fnmatch
import os
import time


class CheckCases:
    def __init__(self, description):
        self.description = description
        self.cases = {}
        self.workers = {}

    def add(self, name, operation, *arguments, **options):
        if name in self.cases:
            raise ValueError('Duplicate check: ' + name)
        self.cases[name] = partial(operation, *arguments, **options)

    def add_parallel(self, name, weight, operation, *arguments, **options):
        if weight < 1:
            raise ValueError('Worker allocation must be positive')
        self.add(name, operation, *arguments, **options)
        self.workers[name] = weight

    def main(self, arguments=None):
        parser = argparse.ArgumentParser(description=self.description)
        parser.add_argument('--jobs', type=int, default=os.environ.get('ACOUPLET_CHECK_JOBS', min(4, os.cpu_count() or 1)), help='Concurrent cases (default: up to 4; use 1 for serial execution).')
        parser.add_argument('--filter', default='*', help='Run case names matching this shell wildcard (default: all cases).')
        parser.add_argument('--list', action='store_true', help='List matching cases without running them.')
        options = parser.parse_args(arguments)
        if options.jobs < 1:
            parser.error('--jobs must be positive')
        selected = {name: operation for name, operation in self.cases.items() if fnmatch.fnmatchcase(name, options.filter)}
        if not selected:
            parser.error('No checks match ' + options.filter)
        if options.list:
            print('\n'.join(selected))
            return
        jobs = min(options.jobs, sum(min(options.jobs, self.workers.get(name, 1)) for name in selected))
        workers = f'{jobs} worker' + ('s' if jobs != 1 else '')
        count = f'{len(selected)} check' + ('s' if len(selected) != 1 else '')
        print(f'Running {count} with {workers}.', flush=True)
        started = time.perf_counter()
        pending = dict(selected)
        running = {}
        available = jobs
        with ThreadPoolExecutor(max_workers=jobs) as executor:
            try:
                while pending or running:
                    for name, operation in list(pending.items()):
                        weight = min(jobs, self.workers.get(name, 1))
                        if weight <= available:
                            running[executor.submit(operation)] = (name, weight)
                            available -= weight
                            del pending[name]
                    completed, _ = wait(running, return_when=FIRST_COMPLETED)
                    for future in completed:
                        name, weight = running.pop(future)
                        available += weight
                        try:
                            future.result()
                        except Exception as error:
                            raise RuntimeError(f'{name}: {error}') from error
                        print(name + ': passed', flush=True)
            except BaseException:
                for future in running:
                    future.cancel()
                raise
        print(f'{count} passed in {time.perf_counter() - started:.1f}s ({workers}).')

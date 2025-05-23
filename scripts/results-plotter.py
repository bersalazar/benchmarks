#!/usr/bin/env python3

"""
Script for plotting aggregated benchmark results, grouping them by scenario.
Generated png files are stored in the source directory.

usage: results-plotter.py [-h] [--group-by GROUP_BY] [--filter FILTER] [--exclude EXCLUDE] [--percentiles-range-max PERCENTILES_RANGE_MAX] [--title TITLE] directory

The script expects files to be in the format

    <type>_<scenario>_<parameters>-report.hgrm

e.g.

    echo_java_instance=c5n.9xlarge_window=2m_mtu=8192_so_sndbuf=2m_so_rcvbuf=2m_rcvwnd=2m_rate=100000_batch=1_length=1344-report.hgrm
"""

import argparse
import os
import tempfile
import shutil
import re
import sys
from collections import defaultdict

regex_common = re.compile('(?P<type>[a-z-]+)_(?P<scenario>[^_]+)_(?P<params>([^=_]+=[^_]+_?)+)-report.hgrm')
regex_params = re.compile('([^=_]+)=([^_]+)')


def main():
    parser = argparse.ArgumentParser(description='Plot benchmark results.')
    parser.add_argument('directories', nargs='+', help='list of directories containing the aggregated results.')
    parser.add_argument('--group-by', default='scenario', help='comma-separated list of fields by which to group the results on a graph. Example: instance,msgsize')
    parser.add_argument('--filter', help='comma-separated list of fields to filter for (include). multiple values should be repeated, Example: msgsize=32,msgsize=288,scenario=c-ats')
    parser.add_argument('--exclude', help='comma-separated list of fields to filter for (exclude). for. multiple values should be repeated, Example: msgsize=1344,scenario=java')
    parser.add_argument('--percentiles-range-max', default='99.9999', help='maximum percentiles to display. Example: 99.999')
    parser.add_argument('--title', help='custom title for the graphs')
    parser.add_argument('--recursive', help='recursively looks for aggregated results in child directories', action='store_true')
    parser.add_argument('--hide-field-name', help='hides the field names in labels', action='store_true')
    parser.add_argument('--hide-summaries', help='hides the summary boxes', action='store_true')
    parser.add_argument('--output-units', default='us', help='output time unit. Defaults to `us`')
    args = parser.parse_args(args=None if sys.argv[1:] else ['--help'])

    group_by = args.group_by.strip().split(',')
    filters = parse_filter(args.filter)
    excludes = parse_filter(args.exclude)

    paths = []
    for dir in args.directories:
        path = os.path.abspath(dir)
        if not os.path.exists(path):
            sys.exit('Directory ' + dir + ' does not exist.')

        if args.recursive:
            lookup_results_recursive(path, paths)
        else:
            if not has_processable_files(path):
                sys.exit("No files in the correct format found in {}, expected files with names like <type>_<scenario>_[p1=v1_p2=v2_...]_sha=<sha1>-report.hgrm".format(path))
            paths.append(path)

    output_path = os.path.abspath(args.directories[0])

    plot_graphs(output_path, paths, args.percentiles_range_max, regex_common, group_by, filters, excludes, args.title, args.hide_field_name, args.hide_summaries, args.output_units)


def lookup_results_recursive(path, paths):
    for dir in os.scandir(path):
        if dir.is_dir():
            new_path = os.path.abspath(dir)
            if has_processable_files(new_path):
                # stop here, keep the dir
                paths.append(new_path)
            else:
                lookup_results_recursive(new_path, paths)


def plot_graphs(output_path, paths, percentiles_range_max, regex, group_by, filters, excludes, custom_title, hide_field_name, hide_summaries, output_units):
    """Plots the graphs by invoking hdr-plot"""

    files = []
    for path in paths:
        files.extend(list((parse_file_name(file) for file in os.scandir(path) if re.match(regex, file.name))))

    grouped = defaultdict(list)

    accepted_files = filter_files(filter_files(files, filters), excludes, exclude=True)

    for f in accepted_files:
        keys = get_key_fields(f, group_by)
        key = tuple(keys .items())
        grouped[key].append(f)

    for key in grouped.keys():
        with tempfile.TemporaryDirectory() as tmpdir:
            grouped_files = []
            for f in grouped[key]:
                field_values = []
                for field in group_by:
                    # rename this for hdr-plot
                    valid_field_name = field.replace('.', '-')
                    valid_field_value = f.fields[field].replace('.', '-')
                    if hide_field_name:
                        field_values.append(valid_field_value)
                    else:
                        field_values.append(f'{valid_field_name}={valid_field_value}')
                grouped_files.append('_'.join(field_values) + '.hgrm')
                shutil.copyfile(f.file.path, os.path.join(tmpdir, '_'.join(field_values) + '.' + 'hgrm'))

            histogram_files = ' '.join(sorted(grouped_files, reverse=False))

            filename, title = get_plot_filename_and_title(key, custom_title)
            os.chdir(tmpdir)
            nosummary = ''
            if hide_summaries:
                nosummary = ' --nosummary '
            os.system(f'hdr-plot --noversion --units {output_units} --summary-fields=min,median,p99,p999,p9999,p99999,max --percentiles-range-max={percentiles_range_max} --output {filename} --title "{title}" {nosummary} {histogram_files}')
            shutil.copyfile(os.path.join(tmpdir, filename), os.path.join(output_path, filename))


def has_processable_files(path):
    """Checks if the path has any files that can be processed by the script."""

    files = (file for file in os.scandir(path) if re.match(regex_common, file.name))
    return list(files)


def filter_files(files, filters, exclude=False):
    """Filters the list of files based on the provided filters (inclusive by default, or exclusive)"""

    accepted_files = set()
    for f in files:
        should_append = True
        for filter_field in filters:
            field_value = f.fields[filter_field]
            if field_value in filters[filter_field]:
                if not exclude:
                    should_append = should_append and True
                else:
                    should_append = should_append and False
            else:
                if not exclude:
                    should_append = should_append and False
                else:
                    should_append = should_append and True

        if filters and should_append:
            accepted_files.add(f)

    if not filters:
        accepted_files = files

    return accepted_files


def get_key_fields(benchmark_file, group_by):
    """Returns the fields that should be used as the key to group files by."""

    key = dict(benchmark_file.fields)

    # remove fields we want to group by
    for k in group_by:
        key.pop(k)

    return key


def parse_file_name(file):
    """Returns a BenchmarkFile representation of the file which contains the parsed fields in a useful representation."""

    match = re.search(regex_common, file.name)

    params_str = match.group('params')

    params = dict()
    for k, v in re.findall(regex_params, params_str):
        params[k] = v

    return BenchmarkFile(file=file, type=match.group('type'), scenario=match.group('scenario'), params=params, params_raw=params_str)


def parse_filter(filter_str):
    """Parses a filter command-line argument, expecting the format field1=value1,field1=value2,field2=value3"""

    filters = defaultdict(set)

    if not filter_str:
        return filters

    filter_args = filter_str.strip().split(',')
    for f in filter_args:
        param, value = f.split('=')
        filters[param].add(value)

    return filters


def get_plot_filename_and_title(key, custom_title):
    """Builds a default title and filename for the graph, using the available parameters."""
    fields = dict(key)
    type = fields.pop('type')

    # we're only left with params by now, generate a title from all parameters
    params_title = []
    params_filename = []
    for k, v in fields.items():
        params_title.append(f'{k}={v}')
        params_filename.append(f'{k}-{v}')
    params_title_str = ' '.join(params_title)
    params_filename_str = '_'.join(params_filename)
    title = f'{type}\n {params_title_str}'
    if custom_title:
        title = f'{custom_title}\n {params_title_str}'
    filename = f'{type}_{params_filename_str}.png'

    return filename, title


class BenchmarkFile:
    def __init__(self, file, type, scenario, params, params_raw):
        self.file = file
        self.type = type
        self.scenario = scenario
        self.params = params
        self.params_raw = params_raw

        self.fields = self.to_keys_dict()

    def to_keys_dict(self):
        keys = {
            "type": self.type,
            "scenario": self.scenario
        }
        keys.update(self.params)
        return keys


if __name__ == "__main__":
    main()

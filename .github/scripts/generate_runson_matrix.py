import argparse
import json
import os

def is_running_in_github_actions():
    return os.environ.get("GITHUB_ACTIONS") == "true"

def generate_matrix(run_id: str, runner: str, use_runs_on: bool, test_all_archs: bool):
    amd_to_arm_mapping = {
        "ubuntu-latest": "ubuntu-latest-m-arm",
        "ubuntu-latest-m": "ubuntu-latest-l-arm"
    }
    # Define the simple matrix
    amd64_runner = ["runs-on",f"runner={runner}",f"run-id={run_id}"] if use_runs_on else runner
    arm64_runner = ["runs-on",f"runner={runner}-arm",f"run-id={run_id}"] if use_runs_on else amd_to_arm_mapping[runner]
    target_archs_to_execute = {"amd64": "true"}

    matrix_simple = {
        "target_os": ["linux"],
        "target_arch": list(target_archs_to_execute.keys()),
        "include": [{"target_os": "linux", "target_arch": "amd64", "runs_on":  amd64_runner, "job_name": "Linux AMD 64"}]
    }

    # Check if the current GitHub ref is a tag matching the pattern refs/tags/v*
    current_ref = os.getenv('GITHUB_REF', '')

    if current_ref.startswith('refs/tags/v') or test_all_archs:
        # Define the full matrix for tags
        matrix = json.loads(json.dumps(matrix_simple))
        target_archs_to_execute["arm64"] = "true"
        matrix["target_arch"] = list(target_archs_to_execute.keys())
        matrix["include"].append({"target_os": "linux", "target_arch": "arm64", "runs_on":  arm64_runner, "job_name": "Linux ARM 64" })
    else:
        # Use the simple matrix
        matrix = matrix_simple

    # make a deepcopy of matrix for flavors
    matrix_flavors = json.loads(json.dumps(matrix))
    matrix_flavors["sidecar_flavor"] = ["allcomponents", "stablecomponents"]

    # Write the matrix to the GITHUB_OUTPUT file
    github_output = os.getenv('GITHUB_OUTPUT', '/dev/null')
    with open(github_output, 'a') as f:
        # make it json compatible
        matrix_json = json.dumps(matrix)
        f.write(f"matrix={matrix_json}\n")

        # matrix simple
        matrix_simple_json = json.dumps(matrix_simple)
        f.write(f"matrix_simple={matrix_simple_json}\n")

        # matrix flavors
        matrix_flavors_json = json.dumps(matrix_flavors)
        f.write(f"matrix_flavors={matrix_flavors_json}\n")

        # target archs
        os_target_archs = [f"linux-{target_arch}" for target_arch in target_archs_to_execute.keys()]
        f.write(f"target_arch_executed={' '.join(os_target_archs)}\n")

    if not is_running_in_github_actions():
        print(f"matrix: {matrix_json}\n")
        print(f"matrix_simple: {matrix_simple_json}\n")
        print(f"matrix_flavors: {matrix_flavors_json}\n")
        print(f"target_arch_executed: {os_target_archs}\n")

if __name__ == "__main__":

    parser = argparse.ArgumentParser(
        prog='generate_runsson_matrix',
        description='generate matrix for github actions')
    parser.add_argument('--run_id', type=str, help='github run id')
    parser.add_argument('--runner', type=str, help='github runner', default='regular')
    parser.add_argument('--all_archs', help='test all archs',  action='store_true', default=False)
    args = parser.parse_args()

    use_runson = args.runner not in (
        "ubuntu-latest", # 2 cores
        "ubuntu-latest-m", # 4 cores
        "ubuntu-latest-m-arm",  # 2 cores
        "ubuntu-latest-l-arm" # 4 cores
    )

    generate_matrix(args.run_id, args.runner, use_runson, args.all_archs)
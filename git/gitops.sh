#!/bin/bash
access_token="glpat-xdfadfa"
gitlab_host_url="https://gitlab.xxx.cn"
function checkout_remote_branch() {
    remote_branch_name=$1
    root_path=$(git rev-parse --show-toplevel)
    
    for submodule_path in $(git config --file .gitmodules --get-regexp path |awk '{print $2}');do
        submodule_name=$(basename "$submodule_path")
        # Get the current branch name in the submodule
        current_branch=$(git -C "$submodule_path" symbolic-ref --short HEAD 2>/dev/null)
        if [[ $current_branch == "$remote_branch_name" ]]; then
            echo "Branch '$remote_branch_name' is already checked out in submodule '$submodule_name'."
        else
            # List remote branches in the submodule
            submodule_remote_branches=$(git -C "$submodule_path" branch -r)
            
            # Check if the remote branch exists in the submodule
            if [[ $submodule_remote_branches =~ "origin/$remote_branch_name" ]]; then
                echo "Checking out branch '$remote_branch_name' in submodule '$submodule_name'..."
                
                # Fetch the latest remote branches in the submodule
                git -C "$submodule_path" fetch
                
                # Check out the remote branch in the submodule
                git -C "$submodule_path" checkout "$remote_branch_name"
            else
                echo "Remote branch '$remote_branch_name' does not exist in submodule '$submodule_name'."
            fi
        fi
    done
}

function get_merge_requests(){
    for submodule_path in $(git config --file .gitmodules --get-regexp path |awk '{print $2}');do
        submodule_name=$(basename "$submodule_path")
        # Get the current branch name in the submodule
        current_branch=$(git -C "$submodule_path" symbolic-ref --short HEAD 2>/dev/null)
        cd "$submodule_path"
        gitlab_url=$(git remote get-url origin | sed 's/\.git$//') # Extract GitLab URL
        
        # 替换 SSH URL 中的协议、主机和端口
        project_id=$(get_project_id $gitlab_url)
        echo "${project_id}"
        # GitLab API endpoint to get project information
        api_url="$gitlab_host_url/api/v4/projects/${project_id}/merge_requests?state=opened"
        
        # Make API request to get project information
        response=$(curl --insecure --header "Private-Token: $access_token" "$api_url")
        
        # Extract project ID from API response
        if [[ "$response" != "[]" ]];then
            merge_request_iid=$(echo "$response" | jq --arg namespace "$namespace" '.[] | select(.namespace.path == $namespace) | .merge_request_iid')
            
            # Check if merge request can be fast-forwarded
            response=$(curl --request GET --header "Private-Token: YOUR_PRIVATE_TOKEN" \
            "$api_url/projects/$project_id/merge_requests/$merge_request_iid/fast-forward")
            
            # Parse the response to check if fast-forward is possible
            can_fast_forward=$(echo "$response" | jq '.can_fast_forward')
            
            # Check the value of 'can_fast_forward'
            if [[ "$can_fast_forward" == "true" ]]; then
                echo "Merge request can be fast-forwarded."
                merge_api_url="$gitlab_host_url/api/v4/projects/${project_id}/merge_requests/${merge_request_iid}/merge?should_remove_source_branch=true&merge_commit_message=squash"
                response=$(curl -X PUT --insecure --header "Private-Token: $access_token" "$merge_api_url")
            else
                echo "Merge request cannot be fast-forwarded."
            fi
            
        fi
        cd -
        return
    done
}

function list_project_with_branch(){
    origin_branch=$1
    for submodule_path in $(git config --file .gitmodules --get-regexp path |awk '{print $2}');do
        submodule_name=$(basename "$submodule_path")
        # Get the current branch name in the submodule
        current_branch=$(git -C "$submodule_path" symbolic-ref --short HEAD 2>/dev/null)
        cd "$submodule_path" > /dev/null 2>&1
        if [[ $current_branch =~ "$origin_branch" ]]; then
            echo "$submodule_name"
        fi
        cd - > /dev/null 2>&1
    done
}

function create_merge_request() {
    origin_branch=$1
    target_branch=$2
    for submodule_path in $(git config --file .gitmodules --get-regexp path |awk '{print $2}');do
        submodule_name=$(basename "$submodule_path")
        # Get the current branch name in the submodule
        current_branch=$(git -C "$submodule_path" symbolic-ref --short HEAD 2>/dev/null)
        cd "$submodule_path"
        if [[ $current_branch =~ "$origin_branch" ]]; then
            echo "Creating merge request for branch '$origin_branch' in submodule '$submodule_name'..."
            # List remote branches
            remote_branches=$(git branch -r)
            
            # Check if the target branch exists
            if [[ $remote_branches =~ "origin/$target_branch" ]]; then
                echo "Target branch '$target_branch' already exists."
            else
                # Create a new remote branch
                git push origin $origin_branch:$target_branch
                echo "Created remote branch '$target_branch'."
            fi
            gitlab_url=$(git remote get-url origin | sed 's/\.git$//') # Extract GitLab URL
            
            # 替换 SSH URL 中的协议、主机和端口
            project_id=$(get_project_id $gitlab_url)
            echo "${project_id}"
            create_gitlab_merge_request "${project_id}" "${origin_branch}" "${target_branch}"
        else
            echo "Current branch $current_branch not matching origin branch '$origin_branch' in submodule '$submodule_name'."
        fi
        cd -
    done
}

function get_project_id(){
    # GitLab SSH URL
    ssh_url="$1"
    
    # Extract namespace and project name from SSH URL
    namespace=$(echo "$ssh_url" | awk -F':' '{print $3}' | awk -F'/' '{print $2}')
    project=$(echo "$ssh_url" | awk -F':' '{print $3}' | awk -F'/' '{print $3}')
    
    # GitLab API endpoint to get project information
    api_url="$gitlab_host_url/api/v4/projects?search=$project&simple=true"
    
    # Make API request to get project information
    response=$(curl --insecure --header "Private-Token: $access_token" "$api_url")
    
    # Extract project ID from API response
    project_id=$(echo "$response" | jq --arg namespace "$namespace" '.[] | select(.namespace.path == $namespace) | .id')
    
    # Print project ID
    echo "$project_id"
}

function create_gitlab_merge_request(){
    #!/bin/bash
    
    # 设置 GitLab URL、项目 ID 和访问令牌
    gitlab_url="$gitlab_host_url/api/v4"
    project_id=$1
    
    # 设置要创建的 Merge Request 的参数
    source_branch="$2"
    target_branch="$3"
    title="New Merge Request"
    description="This is a new Merge Request from ${source_branch} to ${target_branch}."
    
    # 发起 API 请求创建 Merge Request
    curl --insecure --header "PRIVATE-TOKEN: $access_token" \
    --request POST \
    --data "source_branch=$source_branch" \
    --data "target_branch=$target_branch" \
    --data "title=$title" \
    --data-urlencode "description=$description" \
    "$gitlab_url/projects/$project_id/merge_requests"
}

# Usage: ./gitops.sh -c <remote-branch-name> OR ./gitops.sh -m <origin-branch> <target-branch>
while getopts "c:m:l:g" flag; do
    case $flag in
        c) checkout_remote_branch "$OPTARG" ;;
        m)
            origin_branch=$2
            target_branch=$3
            create_merge_request $origin_branch $target_branch
            shift 2
        ;;
        l) list_project_with_branch $OPTARG ;;
        g) get_merge_requests ;;
        *) echo "Invalid flag" ;;
    esac
done
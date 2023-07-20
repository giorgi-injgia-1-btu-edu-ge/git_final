

#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ "${bash_trace:-0}" == "1" ]]; then
    set -o xtrace
fi


delete_temporary_directories() {
  echo "Interrupt signal received. Deleting all temp folders..."
  rm -rf $code_repo_path
  rm -rf $report_repo_path
  rm -rf $pytest_report_path
  rm -rf $black_report_path
  rm -rf $black_output_path
  exit 1
}

check_necessary_modules() {
    packages=("pytest" "pytest-html" "black")

    for package in "${packages[@]}"; do
        if ! pip show "$package" >/dev/null 2>&1; then
            echo "$package is not installed."
            exit 1
        fi
    done
}


perform_git_bisect_for_pytest() {
    # Start the bisect process
    git bisect start

    # Specify the current commit as the bad commit
    git bisect bad $1

    good_commit=$(git log  --pretty=oneline --reverse | grep "pytest_passed*" | head -n 1 | cut -d " " -f 1)

    git bisect good $good_commit

    commit_info=$(git bisect run bash -c "pytest --verbose 2>&1" | grep -o '\[[^]]*\] pytest_failed*')


    # Finish the bisect process
    git bisect reset

    echo "$commit_info"
}


perform_git_bisect_for_black() {
    # Start the bisect process
    git bisect start

    # Specify the current commit as the bad commit
    git bisect bad $1

    good_commit=$(git log  --pretty=oneline --reverse | grep "black_passed$" | head -n 1 | cut -d " " -f 1)

    git bisect good $good_commit

    commit_info=$(git bisect run bash -c "black --check --diff *.py 2>&1" | grep -o '\[[^]]*\] black_failed$')


    # Finish the bisect process
    git bisect reset

    echo "$commit_info"
}


check_pytest() {
    # Checking files with pytest
    if pytest --verbose --html="$1" --self-contained-html > /dev/null
    then
        pytest_result=$?
        echo $pytest_result
    else
        pytest_result=$?
        echo $pytest_result
    fi
}


check_black() {
    # checking files with black
    black_output_path=$1
    if black --check --diff *.py > $black_output_path
    then
        black_result=$?
        echo $black_result
    else
        black_result=$?
        echo $black_result
        cat $black_output_path | pygmentize -l diff -f html -O full,style=solarized-light -o $black_report_path
    fi

}

github_api_get_request()
{
    curl --request GET \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $github_access_token" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$2" \
        --silent \
        "$1"
        #--dump-header /dev/stderr \
}

github_post_request()
{
    curl --request POST \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $github_access_token" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --header "Content-Type: application/json" \
        --silent \
        --output "$3" \
        --data-binary "@$2" \
        "$1"
        #--dump-header /dev/stderr \
}

function jq_update()
{
    local io_path=$1
    local temp_path=$(mktemp)
    shift
    cat $io_path | jq "$@" > $temp_path
    mv $temp_path $io_path
}


# check if all required paramteres are entered
if [ "$#" -ne 5 ]; then
    echo """
    Arguments required to run the code:
    1. URL of repository with source code
    2. Dev branch name in repository with source code
    3. Prod branch name in repository with source code
    4. URL of repository to which pytest and black reports should be uploaded
    5. Branch name in repository to which pytest and black reports should be uploaded
    """
    exit 1
fi

# input variables
code_repo_url=$1
code_branch_name=$2 
release_branch_name=$3
report_repo_url=$4 
report_branch_name=$5 

last_commit=""

code_repo_path=$(mktemp --directory)
# code_repo_path="/home/giorgi/Desktop/git_mid/text"
report_repo_path=$(mktemp --directory)

pytest_report_path=$(mktemp)
black_output_path=$(mktemp)
black_report_path=$(mktemp)

pytest_result=0
black_result=0


# delete temprorary directories after inpterupting the code
trap delete_temporary_directories SIGINT
trap delete_temporary_directories SIGTSTP
trap delete_temporary_directories EXIT


# check if all necessary modules are installed 
check_necessary_modules

# clone code and report repositories
git clone $code_repo_url $code_repo_path &
git clone $report_repo_url $report_repo_path &

wait

pushd $report_repo_path

report_remote_url=$(git remote show origin -n | grep "Fetch URL" | cut -d ":" -f 2-)
report_repo_owner=$(echo "$report_remote_url" | awk -F'[:/]' '{print $2}')
report_repo_name=$(basename "$report_remote_url" .git)


popd


# enter to the report directory to get repository url, repository name and  owner name 
pushd $code_repo_path

remote_url=$(git remote show origin -n | grep "Fetch URL" | cut -d ":" -f 2-)
repo_owner=$(echo "$remote_url" | awk -F'[:/]' '{print $2}')
repo_name=$(basename "$remote_url" .git)

git switch $code_branch_name 

commits=$(git rev-parse HEAD)


# checking for the new commit in every 15 seconds
while true; do

    if [ "$commits" != "$last_commit" ]; then
        echo "new commits : $commits" 

        for current_commit in $commits
        do 
            echo "Commit Hash: $current_commit"
        
            git checkout $current_commit

            author_email=$(git log -n 1 --format="%ae" $current_commit)

            # pytest_files=$(find . -type f -name "*test*.py")
            python_file=$(find . -type f -name "*.py")

            # check if there is a python file in the directory
            if [ -n "$python_file" ]; then
                
                #check if there is a python test file in the folder to process the pytest  

                pytest_result=$(check_pytest $pytest_report_path &)
                black_result=$(check_black  $black_report_path &)

                wait

                echo "\$PYTEST result=$pytest_result \$BLACK result=$black_result"

                popd

                pushd $report_repo_path

                git switch $report_branch_name 

                # creating reports of above tests
                report_path="${current_commit}-$(date +%s)"
                mkdir --parents $report_path

                if [ -f "$pytest_report_path" ]; then

                    mv "$pytest_report_path" "$report_path/pytest.html"
                else
                    echo "pytest_report_path does not exist or is not a regular file"
                fi

                if [ -f "$black_report_path" ]; then
                    mv $black_report_path "$report_path/black.html"
                else
                    echo "black_report_path does not exist or is not a regular file"
                fi

                git add $report_path
                git commit -m "$current_commit report."
                git push
        
                popd

                pushd $code_repo_path


                #  create github issue if there are any error while checking pytest and black
                if (( ($pytest_result != 0) || ($black_result != 0) ))
                then

                    author_username=""
                    response_path=$(mktemp) 

                    github_api_get_request "https://api.github.com/search/users?q=${author_email}" $response_path
                    
                    user_count_total=$(cat $response_path | jq ".total_count")

                    if [[ $user_count_total == 1 ]]
                    then
                        user_json=$(cat $response_path | jq ".items[0]")
                        author_username=$(cat $response_path | jq --raw-output ".items[0].login")
                    fi



                    request_path=$(mktemp)
                    response_path=$(mktemp)
                    echo "{}" > $request_path

                    # start bisect for pytest
                    run_pytest_bisect=$(perform_git_bisect_for_pytest $current_commit)
                    pytest_bisect_result=$(echo "$run_pytest_bisect"  | tail -n 1)
                    
                    # start bisect for black
                    run_black_bisect=$(perform_git_bisect_for_black $current_commit)
                    black_bisect_result=$(echo "$run_black_bisect"  | tail -n 1)
                    
                   
                    # generating error message
                    text+="Results of latest checkings

                "
                    if (( $pytest_result != 0 ))
                    then
                        if (( $black_result != 0 ))
                        then
                            title="${current_commit::7} failed unit and formatting tests."
                            text+="
${current_commit} failed unit and formatting tests.

                "
                            text+="
pytest bisect result ${pytest_bisect_result} intoroduced first bug

                "
                            text+="
black bisect result ${black_bisect_result} intoroduced first bug

                "
                            jq_update $request_path '.labels = ["ci-pytest", "ci-black"]'
                        else
                            title="${current_commit::7} failed unit tests."
                            text+="${current_commit} failed unit tests.

                "
                            text+="pytest bisect result ${pytest_bisect_result}

                "
                            jq_update $request_path '.labels = ["ci-pytest"]'
                        fi
                    else
                        title="${current_commit::7} failed formatting test."
                        text+="${current_commit} failed formatting test.

                "
                        text+="black bisect result ${black_bisect_result}

                "
                        jq_update $request_path '.labels = ["ci-black"]'
                    fi


                    text+="
Pytest report: [pytest report](https://github.com/${report_repo_owner}/${report_repo_name}/blob/${report_branch_name}/${report_path}/pytest.html)
                
                "
                   
                    text+="
Black report: [black report](https://github.com/${report_repo_owner}/${report_repo_name}/blob/${report_branch_name}/${report_path}/black.html)
               
                "
                
                    jq_update $request_path --arg title "$title" '.title = $title'
                    jq_update $request_path --arg body  "$text"  '.body = $body'

                    if [[ ! -z $author_username ]]
                    then
                        jq_update $request_path --arg username "$author_username"  '.assignees = [$username]'
                    fi

                    github_post_request "https://api.github.com/repos/${repo_owner}/${repo_name}/issues" $request_path $response_path
                    cat $response_path | jq ".html_url"
                    rm $response_path
                    rm $request_path

                else
                    pushd  $code_repo_path
                    
                    if ! git rev-parse --verify --quiet "${current_commit}-ci-success"; then
                        git tag "${current_commit}-ci-success" $current_commit
                        git push origin "${current_commit}-ci-success"
                    
                    fi



                    git checkout $release_branch_name
                    
                    

                    if git merge "$current_commit";
                    then
                        # Merge successful
                        git push origin "$release_branch_name"
                    else

                        author_username=""
                        response_path=$(mktemp) 

                        github_api_get_request "https://api.github.com/search/users?q=${author_email// /%20}" $response_path

                        user_count_total=$(cat $response_path | jq ".total_count")

                        if [[ $user_count_total == 1 ]]
                        then
                            user_json=$(cat $response_path | jq ".items[0]")
                            author_username=$(cat $response_path | jq --raw-output ".items[0].login")
                        fi

                        request_path=$(mktemp)
                        response_path=$(mktemp)
                        echo "{}" > $request_path

                        text+="Results of last merge
                        
                    "

                        conflict_info=$(git status --porcelain)

                        title="${current_commit::7} merge failed."

                        text+="
The merge of branch ${code_branch_name} into the ${release_branch_name} branch resulted in conflicts.
                    "

                        text+=" 
Conflict Information: ${conflict_info}                       
                    "
                    
                        jq_update $request_path '.labels = ["ci-merge"]'

                        
                        jq_update $request_path --arg title "$title" '.title = $title'
                        jq_update $request_path --arg body  "$text"  '.body = $body'

                        if [[ ! -z $author_username ]]
                        then
                            jq_update $request_path --arg username "$author_username"  '.assignees = [$username]'
                        fi

                        github_post_request "https://api.github.com/repos/${repo_owner}/${repo_name}/issues" $request_path $response_path
                        cat $response_path | jq ".html_url"
                        rm $response_path
                        rm $request_path

                        git merge --abort 

                    fi
                   
                    popd
                fi

                rm -rf $report_path
            fi

            pushd  $code_repo_path
            git switch $code_branch_name 

            last_commit=$current_commit

        
        done
    fi

    sleep 15

    git pull


    current_time=$(date +%s)
    start_time=$((current_time - 15))
    start_time_readable=$(date -d @$start_time +"%Y-%m-%d %H:%M:%S")
    commits=$(git log --after="$start_time_readable" --format="%H"  --quiet)




done

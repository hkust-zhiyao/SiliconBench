FROM siliconbench-eda:1.0
WORKDIR /tests
COPY public/ /tests/public/
COPY private/ /tests/private/
COPY test.sh /tests/test.sh
RUN chmod +x /tests/test.sh /tests/private/policy_filter.py /tests/private/grader/run.py

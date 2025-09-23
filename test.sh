#!/bin/bash
# test.sh - Convenient test runner for NGINX Dev Gateway

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
TEST_TYPE="${1:-quick}"
export NAMESPACE="${NAMESPACE:-nathan}"
export REGISTRY="${REGISTRY:-}"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Show header
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   NGINX Dev Gateway Test Runner       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo

# Show configuration
echo "Configuration:"
echo "  Namespace: $NAMESPACE"
echo "  Registry:  ${REGISTRY:-<not set>}"
echo "  Test Type: $TEST_TYPE"
echo

# Function to run tests
run_tests() {
    local test_type="$1"

    case "$test_type" in
        quick|smoke)
            echo -e "${BLUE}Running quick smoke tests...${NC}"
            "$SCRIPT_DIR/tests/run-tests.sh" quick
            ;;

        unit)
            echo -e "${BLUE}Running unit tests...${NC}"
            "$SCRIPT_DIR/tests/run-tests.sh" unit
            ;;

        docker)
            echo -e "${BLUE}Running Docker container tests...${NC}"
            "$SCRIPT_DIR/tests/run-tests.sh" specific tests/integration/test-docker-container.sh
            ;;

        e2e)
            if [ -z "$REGISTRY" ]; then
                echo -e "${YELLOW}Warning: E2E tests require REGISTRY to be set${NC}"
                echo "Example: REGISTRY=myregistry.azurecr.io ./test.sh e2e"
                exit 1
            fi
            echo -e "${BLUE}Running E2E deployment tests...${NC}"
            "$SCRIPT_DIR/tests/run-tests.sh" specific tests/integration/test-e2e-deployment.sh
            ;;

        routing)
            echo -e "${BLUE}Running gateway routing tests...${NC}"
            TEST_KUBERNETES=1 "$SCRIPT_DIR/tests/integration/test-gateway-routing.sh"
            ;;

        integration)
            echo -e "${BLUE}Running all integration tests...${NC}"
            "$SCRIPT_DIR/tests/run-tests.sh" integration
            ;;

        all)
            echo -e "${BLUE}Running all tests...${NC}"
            "$SCRIPT_DIR/tests/run-tests.sh" all
            ;;

        ci)
            echo -e "${BLUE}Running CI test suite...${NC}"
            # Quick tests first
            "$SCRIPT_DIR/tests/run-tests.sh" quick || exit 1

            # Unit tests
            "$SCRIPT_DIR/tests/run-tests.sh" unit || exit 1

            # Docker tests
            "$SCRIPT_DIR/tests/run-tests.sh" specific tests/integration/test-docker-container.sh || exit 1

            # E2E if registry is available
            if [ -n "$REGISTRY" ]; then
                "$SCRIPT_DIR/tests/run-tests.sh" specific tests/integration/test-e2e-deployment.sh || exit 1
            fi

            echo -e "${GREEN}✓ All CI tests passed!${NC}"
            ;;

        help|--help|-h)
            cat << EOF
Usage: $0 [TEST_TYPE]

TEST TYPES:
  quick     Run quick smoke tests (default)
  unit      Run unit tests
  docker    Run Docker container tests
  e2e       Run end-to-end deployment tests (requires REGISTRY)
  routing   Run gateway routing tests on existing deployment
  integration Run all integration tests
  all       Run all tests
  ci        Run CI test suite

ENVIRONMENT VARIABLES:
  NAMESPACE  Kubernetes namespace (default: nathan)
  REGISTRY   Container registry for E2E tests
  VERBOSE    Show detailed test output (0 or 1)

EXAMPLES:
  # Run quick tests
  $0

  # Run Docker tests
  $0 docker

  # Run E2E tests with registry
  REGISTRY=myregistry.azurecr.io $0 e2e

  # Run routing tests on specific namespace
  NAMESPACE=dev $0 routing

  # Run full CI suite
  REGISTRY=myregistry.azurecr.io $0 ci

EOF
            exit 0
            ;;

        *)
            echo "Unknown test type: $test_type"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Run tests
run_tests "$TEST_TYPE"